#!/usr/bin/env ruby
# Validate the workflow's credential boundary and syntax of each runnable shell step.
require 'yaml'
require 'tempfile'
require 'open3'

root = File.expand_path('..', __dir__)
workflow = YAML.load_file(File.join(root, '.github/workflows/packaging.yml'))
jobs = workflow.fetch('jobs')
verify = jobs.fetch('verify')
raise 'PR verification must not use credentials' if verify.to_s.include?('secrets.') || verify.key?('environment')
build = jobs.fetch('build')
raise 'Signing must use the release environment' unless build['environment'] == 'release'
raise 'Signing must be restricted to tags or manual runs' unless build['if'] == "github.event_name == 'workflow_dispatch' || startsWith(github.ref, 'refs/tags/v')"
cleanup = build.fetch('steps').find { |step| step['name'] == 'Clean up signing keychain' }
raise 'Signing cleanup must run on failure' unless cleanup && cleanup['if'] == 'always()'
count = 0
jobs.each_value do |job|
  job.fetch('steps').each do |step|
    next unless step['run']
    Tempfile.create(['waccom-ci-', '.sh']) do |file|
      file.write(step['run']); file.flush
      output, status = Open3.capture2e('/bin/bash', '-n', file.path)
      raise "Invalid shell in #{step['name']}: #{output}" unless status.success?
    end
    count += 1
  end
end
output, status = Open3.capture2e({'WACCOM_VERSION' => 'not-a-version'}, '/bin/bash', File.join(root, 'script/build_and_run.sh'), '--build')
raise 'Invalid version must be rejected before building' unless status.exitstatus == 2 && output.include?('X.Y.Z')
puts "Workflow credential boundaries and #{count} shell steps checked; invalid release version rejected."
