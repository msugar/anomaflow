import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions, StandardOptions
from apache_beam.io import fileio
import json
import numpy as np
import datetime
import logging

# Define custom options for the pipeline
class TelemetryOptions(PipelineOptions):
    @classmethod
    def _add_argparse_args(cls, parser):
        parser.add_argument('--input_path', 
                            default='gs://your-hackathon-telemetry-bucket/metrics/*.json',
                            help='Path to input files')
        parser.add_argument('--output_path',
                            default='gs://your-hackathon-telemetry-bucket/anomalies/',
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

    def process(self, readable_file):
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

                                            #device = attributes.get('device', 'unknown')

                                            yield {
                                                'timestamp': timestamp,
                                                'metric_name': metric_name,
                                                'value': value,
                                                'resource': resource_attrs.get('host.name', 'unknown'),
                                                #'device': device,
                                                'metric_type': 'gauge'
                                            }

                    except json.JSONDecodeError:
                        logging.warning(f"Could not parse line as JSON in {file_path}: {line[:100]}...")
                    except Exception as e:
                        logging.error(f"Error processing telemetry line in {file_path}: {str(e)}")

        except Exception as file_err:
            logging.error(f"Error opening file {file_path}: {str(file_err)}")


# Detect anomalies in system metrics with integrated logging
class DetectMetricAnomalies(beam.DoFn):
    def process(self, element):
        # Element is a tuple (key, values) where key is (metric_name, resource)
        # and values is a list of metric values in the window
        key, values = element
        metric_name, resource = key
        
        # Log window processing start
        #logging.info(f"Processing window for metric '{metric_name}' on resource '{resource}' with {len(values)} values")
        
        # Skip if not enough data points
        if len(values) < 4:
            #logging.warning(f"Insufficient data points ({len(values)}) for metric '{metric_name}' on resource '{resource}'. Minimum required: 4")
            return []
        
        # Extract values and convert to NumPy array for vectorized operations
        metric_values = np.array([item['value'] for item in values])
        # Log the metric values for debugging
        #logging.debug(f"Metric values for {metric_name}@{resource}: {metric_values}")
        
        # Calculate statistics using NumPy (vectorized)
        mean_value = np.mean(metric_values)
        std_dev = np.std(metric_values, mean=mean_value) # Using the mean keyword to save computation time
        min_value = np.min(metric_values)
        max_value = np.max(metric_values)
        
        # Log window statistics
        #logging.info(f"Window stats for {metric_name}@{resource}: mean={mean_value:.3f}, std={std_dev:.3f}, min={min_value:.3f}, max={max_value:.3f}, count={len(metric_values)}")
        
        # Handle edge case where std_dev is 0 (all values are the same)
        if std_dev == 0:
            #logging.info(f"No variance in metric '{metric_name}' on resource '{resource}' (std_dev=0). No anomalies detected.")
            return []  # No anomalies if all values are identical
        
        # Vectorized z-score calculation for ALL values at once
        z_scores = np.abs((metric_values - mean_value) / std_dev)
        # Log z-scores for debugging
        #logging.info(f"Z-scores for {metric_name}@{resource}: {z_scores}")
        
        # Find indices where z-score exceeds threshold (vectorized comparison)
        anomaly_indices = np.where(z_scores > 3.0)[0]
        
        # Log anomaly detection summary
        if len(anomaly_indices) > 0:
            logging.warning(f"Detected {len(anomaly_indices)} anomalies in metric '{metric_name}' on resource '{resource}' (threshold: 3.0 std deviations)")
            # Log details of the most severe anomaly
            max_z_idx = np.argmax(z_scores[anomaly_indices])
            max_z_score = z_scores[anomaly_indices[max_z_idx]]
            max_z_value = metric_values[anomaly_indices[max_z_idx]]
            logging.warning(f"Most severe anomaly: value={max_z_value:.3f}, z-score={max_z_score:.3f}")
        #else:
            #logging.info(f"No anomalies detected in metric '{metric_name}' on resource '{resource}'")
        
        # Generate anomaly records only for detected anomalies
        anomalies = []
        for idx in anomaly_indices:
            z_score = z_scores[idx]
            item = values[idx]
            value = float(metric_values[idx])
            
            # Log individual anomaly details
            #logging.warning(f"Anomaly detected: {metric_name}@{resource} at {item['timestamp']}, value={value:.3f}, z-score={z_score:.3f}")
            
            anomalies.append({
                'timestamp': item['timestamp'],
                'detection_time': datetime.datetime.now().isoformat(),
                'metric_name': metric_name,
                'resource': resource,
                'value': value,
                'mean_value': float(mean_value),
                'std_dev': float(std_dev),
                'z_score': float(z_score),
                'anomaly_type': 'metric_anomaly',
                'severity': 'high' if z_score > 5 else 'medium',
                'window_size': len(metric_values),
                'value_index': int(idx)  # Position within the window
            })
        
        #logging.info(f"Completed processing window for {metric_name}@{resource}. Generated {len(anomalies)} anomaly records.")
        return anomalies
    

# Main pipeline
def run(argv=None):  # pylint: disable=missing-docstring
    pipeline_options = PipelineOptions(argv)
    telemetry_options = pipeline_options.view_as(TelemetryOptions)
    #pipeline_options.view_as(StandardOptions).streaming = True
    
    with beam.Pipeline(options=pipeline_options) as p:
        # Read from GCS
        files = (
            p 
            | 'Match Files' >> fileio.MatchFiles(telemetry_options.input_path)
            | 'Read Matches' >> fileio.ReadMatches()
        )
        
        # Parse telemetry data
        parsed_data = files | 'Parse Telemetry' >> beam.ParDo(ParseTelemetryData())
        
        # Split metrics and logs
        # metrics, logs = (
        #     parsed_data 
        #     | 'Split Metrics and Logs' >> 
        #         beam.Partition(lambda x, _: 0 if x.get('metric_type') == 'gauge' else 1, 2)
        # )
        
        # Process metrics with windowing
        windowed_metrics = (
            parsed_data
            | 'Add Metric Timestamps' >> 
                beam.Map(
                    lambda x: beam.window.TimestampedValue(
                        x, 
                        datetime.datetime.fromisoformat(x['timestamp']).timestamp()
                    )
                )
                
            # TRADE-OFF: With overlapping windows, the same data point can be 
            # processed multiple times, potentially leading to duplicate 
            # anomaly detections. With non-overlapping windows, each data point is
            # processed once per window, which can be more efficient but may miss
            # anomalies that occur at the edges of the windows.
            
            # Overlapping windows
            # If you want to avoid duplicates, consider using a different 
            # windowing strategy or deduplication logic.
            # | 'Window Metrics' >> 
            #     beam.WindowInto(
            #         beam.window.SlidingWindows(
            #             size=telemetry_options.window_size, 
            #             period=telemetry_options.window_size // 2
            #         )
            #     )
            
            # Non-overlapping windows
            | 'Window Metrics' >> 
                beam.WindowInto(
                    beam.window.FixedWindows(telemetry_options.window_size)
                )
                
            | 'Key Metrics' >> 
                beam.Map(
                    lambda x: ((x['metric_name'], x['resource']), x)
                )
            | 'Group Metrics' >> beam.GroupByKey()
        )
        
        anomaly_results = (
            windowed_metrics
            | 'Detect Metric Anomalies' >> beam.ParDo(DetectMetricAnomalies())
        )
        
        # Write anomalies
        (anomaly_results
            | 'Format Anomalies' >> beam.Map(json.dumps)
            | 'Write Anomalies' >> 
                beam.io.WriteToText(
                    telemetry_options.output_path + 'anomalies',
                    file_name_suffix='.json'
                )
        )

if __name__ == '__main__':
    logging.getLogger().setLevel(logging.INFO)
    run()