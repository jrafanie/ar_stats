# Wrap the normal log method with ours so we can track the sql queries, results, timings, and callsites
ActiveRecord::Base.connection.class.class_eval do
  def log_with_ar_stats(sql, name, &block)
    old_runtime = @runtime
    result = log_without_ar_stats(sql, name, &block)
    seconds = @runtime - old_runtime
    ARStats.instance.track_sql_call(sql, name, seconds, result)
    result
  end

  alias_method_chain :log, :ar_stats
end
