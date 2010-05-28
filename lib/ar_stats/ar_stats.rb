require 'sync'
class ARStats
  def self.instance
    @instance ||= ARStats.new
  end

  def self.log_ar_stats(*args)
    ARStats.instance.log_ar_stats(*args)
  end

  attr_reader :adapter_name

  def initialize
    @adapter_name = ActiveRecord::Base.connection_pool.spec.config[:adapter] rescue ""
    @stats_sync = Sync.new
    @stats = Hash.new(0)
    @callsites = Hash.new
    @stats_enabled = @traffic_interval = nil
    @callsites_enabled = @callsites_depth = @callsites_min_threshold = nil
    @app_path_regexp, @logger = nil
    @stats_last_logged = Time.now
  end

  def launching_process
    @launching_process ||= $$
  end

  def callsite_file
    @callsite_file ||= begin
      callsite_dir = Object.const_defined?('RAILS_ROOT') ? RAILS_ROOT : '.'
      callsite_dir = File.join(callsite_dir, "log")
      Dir.mkdir(callsite_dir) unless File.exists?(callsite_dir)
      File.join(callsite_dir, "callsites_#{self.launching_process}.log")
    end
  end

  def track_sql_call(sql, name, seconds, result = nil)
    # Initialize the enabled flag and interval if the enabled flag is nil
    return unless @stats_enabled

    # Don't capture db_statistics unless we're enabled
    return if @logger.nil?

    #@logger.debug("sql: #{sql[0..30]}, result: #{result.class.name}")
    if result.nil? || result.is_a?(Array) || result.is_a?(String)
      request_size = sql.length
      response_size = self.response_size(result)
    end

    @stats_sync.synchronize(:EX) do
      # Increment the seconds for all log_info calls (including when the result is nil/PGResult/ODBC statement)
      @stats[:db_seconds] += seconds
      @stats[:max_db_seconds] = seconds if seconds > @stats[:max_db_seconds]

      # A nil result indicates a completed sql request with an empty response (ie, commit, rollback)
      # An array result indicates a completed sql request with an array of rows returned (such as for a select)
      # A result that is a Statement handle or PGResult, etc., is a handle that indicates the sql request isn't complete, so skip updating it
      #@logger.debug("sql: #{sql[0..30]}, request_size: #{request_size}, response_size: #{response_size}")
      if request_size && response_size
           
        if @callsites_enabled
          nesting = []
          subhash = @callsites
          caller.each do |site|
            if site =~ @app_path_regexp
              unless nesting.empty?
                nesting.each {|n| subhash = subhash[n] if subhash.has_key?(n)}
              end
              subhash[site] ||= {}
              subhash[site]['count'] ||= 0
              subhash[site]['count'] += 1
              nesting << site
              break if nesting.length == @callsites_depth
            end
          end
        end

        @stats[:requests] += 1
        @stats[:requests_total_size] += request_size
        @stats[:request_max_size] = request_size if request_size > @stats[:request_max_size]

        @stats[:responses] += 1
        @stats[:responses_total_size] += response_size
        @stats[:response_max_size] = response_size if response_size > @stats[:response_max_size]

        # Capture the current connection information for logging purposes
        if ActiveRecord::Base.connection_pool
          @stats[:established_connections] = ActiveRecord::Base.connection_pool.instance_variable_get(:@connections).length
          @stats[:connection_pool_size] = ActiveRecord::Base.connection_pool.instance_variable_get(:@size)
          @stats[:reserved_connections] = ActiveRecord::Base.connection_pool.instance_variable_get(:@reserved_connections).keys.length
        end
      end
    end
    self.log_ar_stats
  end

  def update_config(options = {})
    @stats_sync.synchronize(:EX) do
      @traffic_interval = options[:interval] || 60
      enabled_before = @stats_enabled.to_s.downcase == "true"

      @stats_enabled = options[:enabled].to_s.downcase == "true"
      @callsites_enabled = options[:callsites_enabled].to_s.downcase == "true"
      @callsites_depth = options[:callsites_depth] || 5
      @callsites_min_threshold = options[:callsites_min_threshold] || 5
      @app_path_regexp = options[:app_path_regexp]
      @logger = options[:logger] || RAILS_DEFAULT_LOGGER
      @launching_process_lambda = options[:launching_process_lambda]
      @launching_process = @launching_process_lambda.call if @launching_process_lambda.is_a?(Proc)
      
      if enabled_before != @stats_enabled
        action = @stats_enabled == true ? "Enabling" : "Disabling"
        @logger.info("(#{self.adapter_name}) #{action} active record statistics #{"with interval [#{@traffic_interval}]" if @stats_enabled}")
        self.log_ar_stats(true) unless @stats_enabled
      end
    end
  end

  def log_ar_stats(force = false)
    # Don't log empty stats or if we're disabled and not forced
    #@logger.debug("XXX: @stats_enabled: #{@stats_enabled}, @stats.blank?: #{@stats.blank?}") if @logger && force
    return if !@stats_enabled && !force
    return if @stats.blank?
    now = Time.now
    seconds_since_logged = now - @stats_last_logged

    # Log and reset the current stats if "forced" (such as process shutdown) or if the interval has expired
    if force || seconds_since_logged > @traffic_interval.seconds
      @stats_sync.synchronize(:EX) do
        self.do_log_ar_stats(seconds_since_logged)
        self.do_log_db_callsites(seconds_since_logged)
        self.clear_stats
        @stats_last_logged = now
      end
    end
  end

  def do_log_ar_stats(seconds_since_logged)
    @logger.info("(#{self.adapter_name}-log_ar_stats) interval: #{@traffic_interval} seconds, last logged: #{seconds_since_logged} seconds ago: (Sizes are estimated) #{@stats.inspect}")
  end

  def do_log_db_callsites(seconds_since_logged)
    if @callsites_enabled
      callsites = @callsites.sort {|a,b| b[1]['count'] <=> a[1]['count']}
      File.open(self.callsite_file, "a") do |f|
        f.puts "*" * 50
        f.puts "#{Time.now.utc.to_s} PID: #{Process.pid.to_s} - Total DB requests: #{@stats[:requests]} for #{self.launching_process} in the past #{seconds_since_logged} seconds..."
        f.puts "count      callsite"
        print_hash(f, callsites)
      end
    end
  end

  def clear_stats
    @callsites.clear if @callsites_enabled
    @stats_last_logged = Time.now
    @stats.clear
  end

  def print_hash(f, hsh, indent = nil, parent = nil)
    hsh.each do |k, v|
      next unless v.is_a?(Hash)
          
      # Skip any root level hashes with less than the threshold number of db requests
      next if parent.nil? && v["count"] <= @callsites_min_threshold
      indent = 0 if indent.nil?
      spaces = " " * indent
      of_parent = parent.nil? ? "" : "of #{parent}"
      f.puts "#{spaces}#{v["count"]} #{of_parent}     #{k}"
      if v.keys.length > 1
        print_hash(f, v, indent + 2, v["count"])
      end
    end
  end

  def response_size(response)
    case response
    when Array
      # Estimate the response size by multiplying the number of rows by the length of the first row
      size = response.length * response.first.to_s.length
      # real_size = response.inject(0) {|sum, res| res.to_s.length + sum}
      # @logger.info("XXX [#{response.class}], estimate: #{size}, real: #{real_size}")
      size
    when String
      response.length
    when NilClass
      0
    else
      @logger.warn("(#{self.adapter_name}-response_size) Unable to detect size of response type: [#{response.class}]")
      response.respond_to?(:length) ? response.length : 0
    end
  end
end

at_exit do
  # Log the current database traffic stats before exiting (force it by passing true)
  begin
    ARStats.log_ar_stats(true)
  rescue Exception => err
    puts "Failed to log AR stats at exit due to #{err.to_s}" rescue nil
  end
end