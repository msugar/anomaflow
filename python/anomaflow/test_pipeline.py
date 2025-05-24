import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions
import argparse
import datetime

def run_test_pipeline(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    known_args, pipeline_args = parser.parse_known_args(argv)
    
    pipeline_options = PipelineOptions(pipeline_args)
    
    with beam.Pipeline(options=pipeline_options) as p:
        (p 
         | 'Create' >> beam.Create(['Hello', 'World', 'Test'])
         | 'Add timestamp' >> beam.Map(lambda x: f"{datetime.datetime.now(datetime.timezone.utc).isoformat()}: {x}")
         | 'Write' >> beam.io.WriteToText(known_args.output))

if __name__ == '__main__':
    run_test_pipeline()