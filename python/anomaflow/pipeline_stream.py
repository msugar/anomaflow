import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions, StandardOptions
from apache_beam.io import fileio
import apache_beam.io.gcp.pubsub as pubsub # Import for PubsubMessage
import json
import numpy as np
import datetime
import logging
import base64 # Needed for parsing GCS notifications

# Define custom options for the pipeline
class TelemetryOptions(PipelineOptions):
    @classmethod
    def _add_argparse_args(cls, parser):
        parser.add_argument('--pubsub_subscription',
                            required=True,
                            help='Pub/Sub subscription for GCS notifications (e.g., projects/YOUR_PROJECT_ID/subscriptions/YOUR_SUB_ID)')
        parser.add_argument('--input_file_suffix',
                            default='.json',
                            help='Suffix for input files to process (e.g., .json)')
        parser.add_argument('--input_path_prefix',
                            default='metrics/', # e.g. "metrics/" to only process files under this GCS path prefix
                            help='GCS object path prefix to filter notifications (e.g., metrics/)')
        parser.add_argument('--output_path',
                            default='gs://your-hackathon-telemetry-bucket/anomalies_stream/', # Adjusted default for clarity
                            help='Output path for anomalies')
        parser.add_argument('--window_size',
                            default=60 * 10,  # 10 minutes
                            type=int,
                            help='Window size in seconds')

# Parse OpenTelemetry metrics
class ParseTelemetryData(beam.DoFn):
    def safe_unix_nano_to_iso(self, nano):
        try:
            return datetime.datetime.fromtimestamp(int(nano) / 1e9).isoformat()
        except (ValueError, TypeError):
            logging.warning(f"Invalid timeUnixNano value: {nano}")
            return None

    def process(self, readable_file: fileio.ReadableFile):
        file_path = getattr(readable_file.metadata, "path", "unknown")
        try:
            with readable_file.open() as f:
                for line in f:
                    try:
                        data = json.loads(line)

                        if 'resourceMetrics' not in data:
                            continue

                        for resource_metrics in data.get('resourceMetrics', []):
                            resource = resource_metrics.get('resource', {})
                            resource_attrs = {
                                attr.get('key'): attr.get('value', {}).get('stringValue')
                                for attr in resource.get('attributes', [])
                            }

                            for scope_metrics in resource_metrics.get('scopeMetrics', []):
                                for metric in scope_metrics.get('metrics', []):
                                    metric_name = metric.get('name')

                                    if 'gauge' in metric:
                                        for point in metric.get('gauge', {}).get('dataPoints', []):
                                            timestamp = self.safe_unix_nano_to_iso(point.get('timeUnixNano'))
                                            if not timestamp:
                                                continue

                                            value = point.get('asDouble')
                                            if value is None:
                                                value = point.get('asInt')
                                            if value is None:
                                                continue

                                            attributes = {
                                                attr.get('key'): attr.get('value', {}).get('stringValue')
                                                for attr in point.get('attributes', [])
                                            }

                                            yield {
                                                'timestamp': timestamp,
                                                'metric_name': metric_name,
                                                'value': value,
                                                'resource': resource_attrs.get('host.name', 'unknown'),
                                                'metric_type': 'gauge'
                                            }

                    except json.JSONDecodeError:
                        logging.warning(f"Could not parse line as JSON in {file_path}: {line[:100]}...")
                    except Exception as e:
                        logging.error(f"Error processing telemetry line in {file_path}: {str(e)}")

        except Exception as file_err:
            logging.error(f"Error opening file {file_path}: {str(file_err)}")


# Detect anomalies in system metrics
class DetectMetricAnomalies(beam.DoFn):
    def process(self, element):
        key, values = element
        metric_name, resource = key
        
        if len(values) < 4:
            return []
        
        metric_values = np.array([item['value'] for item in values])
        mean_value = np.mean(metric_values)
        std_dev = np.std(metric_values) 
        
        if std_dev == 0:
            return []
        
        z_scores = np.abs((metric_values - mean_value) / std_dev)
        anomaly_indices = np.where(z_scores > 3.0)[0]
        
        anomalies = []
        for idx in anomaly_indices:
            z_score = z_scores[idx]
            item = values[idx]
            value = float(metric_values[idx])
            
            anomalies.append({
                'timestamp': item['timestamp'],
                'detection_time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'metric_name': metric_name,
                'resource': resource,
                'value': value,
                'mean_value': float(mean_value),
                'std_dev': float(std_dev),
                'z_score': float(z_score),
                'anomaly_type': 'metric_anomaly',
                'severity': 'high' if z_score > 5 else 'medium',
                'window_size': len(metric_values),
                'value_index': int(idx)
            })
        return anomalies

# Parse GCS notifications from Pub/Sub
class ParseGCSNotification(beam.DoFn):
    def __init__(self, file_suffix_filter=".json", path_prefix_filter=None):
        self.file_suffix_filter = file_suffix_filter
        self.path_prefix_filter = path_prefix_filter if path_prefix_filter else ""

    def process(self, message: pubsub.PubsubMessage):
        try:
            attributes = message.attributes
            event_type = attributes.get('eventType')
            object_id = attributes.get('objectId')  # File name/path within the bucket
            bucket_id = attributes.get('bucketId')

            # Process only new object finalization events
            if event_type == 'OBJECT_FINALIZE':
                if object_id and bucket_id:
                    # Apply filters
                    if not object_id.endswith(self.file_suffix_filter):
                        logging.debug(f"Skipping file (suffix mismatch): gs://{bucket_id}/{object_id}")
                        return
                    if not object_id.startswith(self.path_prefix_filter):
                        logging.debug(f"Skipping file (prefix mismatch): gs://{bucket_id}/{object_id}")
                        return
                        
                    file_path = f"gs://{bucket_id}/{object_id}"
                    logging.info(f"Processing GCS notification for: {file_path}")
                    yield file_path
                else:
                    logging.warning(f"Missing bucketId or objectId in notification attributes: {attributes}")
            # else:
            #    logging.debug(f"Ignoring event type {event_type} for object {object_id} in bucket {bucket_id}")

        except Exception as e:
            data_sample = ""
            if message.data:
                try:
                    decoded_data = base64.b64decode(message.data).decode('utf-8', 'ignore')
                    data_sample = decoded_data[:200]
                except Exception:
                    data_sample = "Failed to decode data."
            logging.error(f"Error processing Pub/Sub message. Attributes: {message.attributes}, Data sample: {data_sample}. Error: {e}", exc_info=True)


# Main pipeline
def run(argv=None):
    pipeline_options = PipelineOptions(argv)
    telemetry_options = pipeline_options.view_as(TelemetryOptions)
    
    # Set to streaming mode
    pipeline_options.view_as(StandardOptions).streaming = True
    
    with beam.Pipeline(options=pipeline_options) as p:
        # 1. Read GCS event notifications from Pub/Sub
        gcs_file_paths = (
            p
            | 'Read GCS Notifications' >> beam.io.ReadFromPubSub(
                subscription=telemetry_options.pubsub_subscription,
                with_attributes=True,  # Crucial for accessing eventType, bucketId, objectId
                id_label='pubsub_message_id' # Helps Dataflow de-duplicate messages
            )
            | 'Parse GCS Notification' >> beam.ParDo(
                ParseGCSNotification(
                    file_suffix_filter=telemetry_options.input_file_suffix,
                    path_prefix_filter=telemetry_options.input_path_prefix
                )
            )
            # Output: PCollection of GCS path strings (e.g., "gs://bucket/metrics/file.json")
        )
        
        # 2. Match and Read the files identified by the notifications
        readable_files = (
            gcs_file_paths
            # MatchFiles can take a PCollection of file patterns (exact paths in this case)
            | 'Match Individual Files' >> fileio.MatchFiles()
            # Output: PCollection<MatchResult>
            # Extract FileMetadata from MatchResult
            | 'Extract FileMetadata' >> beam.FlatMap(lambda match_result: match_result.metadata)
            # Output: PCollection<FileMetadata>
            | 'Read Matched Files' >> fileio.ReadMatches()
            # Output: PCollection<ReadableFile>
        )
        
        # 3. Parse telemetry data from the files
        parsed_data = readable_files | 'Parse Telemetry' >> beam.ParDo(ParseTelemetryData())
        
        # 4. Process metrics with windowing for anomaly detection
        windowed_metrics = (
            parsed_data
            | 'Add Metric Timestamps' >> 
                beam.Map(
                    lambda x: beam.window.TimestampedValue(
                        x, 
                        datetime.datetime.fromisoformat(x['timestamp']).timestamp()
                    )
                )
            # Using FixedWindows for non-overlapping windows
            | 'Window Metrics' >> 
                beam.WindowInto(
                    beam.window.FixedWindows(telemetry_options.window_size)
                    # Consider adding allowed_lateness for streaming if data can arrive late:
                    # allowed_lateness=beam.window. VerteidDuration(seconds=...) 
                )
            | 'Key Metrics' >> 
                beam.Map(
                    lambda x: ((x['metric_name'], x['resource']), x)
                )
            | 'Group Metrics' >> beam.GroupByKey()
        )
        
        # 5. Detect anomalies
        anomaly_results = (
            windowed_metrics
            | 'Detect Metric Anomalies' >> beam.ParDo(DetectMetricAnomalies())
        )
        
        # 6. Write anomalies to GCS
        (anomaly_results
            | 'Format Anomalies' >> beam.Map(json.dumps)
            | 'Write Anomalies' >> 
                beam.io.WriteToText(
                    telemetry_options.output_path + 'anomalies', # Output path prefix
                    file_name_suffix='.json',
                    # In streaming, output files will be sharded and named based on window and pane.
                    # num_shards can be set if specific sharding is desired, or use 0 for dynamic.
                    # shard_name_template='' # To use default windowed naming.
                )
        )

if __name__ == '__main__':
    logging.getLogger().setLevel(logging.INFO)
    run()