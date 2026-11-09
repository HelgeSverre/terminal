require 'json'
paths=ARGV.empty? ? Dir["#{__dir__}/[1-4]-*.json"].sort : ARGV
summary=paths.to_h do |path|
 rows=JSON.parse(File.read(path)).map do |r|
  stats=r.fetch('statistics'); diag=stats.fetch('stream_diagnostic')
  raise "incomplete #{path} #{r['workload']}/#{r['mode']}" unless r['input_ms'].size==128 && r['probe_ms'].size==128 && r['geometry_mismatches']==0 && r['admission_failures']==0 && r['reaped'] && stats['bytes_parsed']>1_048_576 && stats['bytes_read']>=stats['bytes_parsed'] && diag['queued_output_bytes_high_water']>0
  percentiles=%w[input_ms probe_ms].to_h{|key|a=r.fetch(key).sort;[key,{p50:a[(a.size*0.5).ceil-1],p95:a[(a.size*0.95).ceil-1],p99:a[(a.size*0.99).ceil-1],max:a.last}]}
  {workload:r['workload'],mode:r['mode'],samples:r['input_ms'].size,backlog_high_water:diag['queued_output_bytes_high_water'],percentiles:percentiles}
 end
 [File.basename(path),rows]
end
puts JSON.pretty_generate(summary)
