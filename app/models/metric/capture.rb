module Metric::Capture
  VALID_CAPTURE_INTERVALS = ['realtime', 'hourly', 'historical'].freeze

  # This is nominally a VMware-specific value, but we currently expect
  # all providers to conform to it.
  REALTIME_METRICS_PER_MINUTE = 3

  REALTIME_PRIORITY = HOURLY_PRIORITY = DAILY_PRIORITY = MiqQueue::NORMAL_PRIORITY
  HISTORICAL_PRIORITY = MiqQueue::LOW_PRIORITY

  # @param [String[ capture interval
  # @return [Integer] MiqQueue priority level for this message
  def self.interval_priority(interval)
    interval == "historical" ? MiqQueue::LOW_PRIORITY : MiqQueue::NORMAL_PRIORITY
  end

  def self.capture_cols
    @capture_cols ||= Metric.columns_hash.collect { |c, h| c.to_sym if h.type == :float && c[0, 7] != "derived" }.compact
  end

  def self.historical_days
    Settings.performance.history.initial_capture_days.to_i
  end

  def self.historical_start_time
    historical_days.days.ago.utc.beginning_of_day
  end

  def self.concurrent_requests(interval_name)
    requests = ::Settings.performance.concurrent_requests[interval_name]
    requests = 20 if requests < 20 && interval_name == 'realtime'
    requests
  end

  def self.standard_capture_threshold(target)
    target_key = target.class.base_model.to_s.underscore.to_sym
    minutes_ago(::Settings.performance.capture_threshold[target_key] ||
                ::Settings.performance.capture_threshold.default)
  end

  def self.alert_capture_threshold(target)
    target_key = target.class.base_model.to_s.underscore.to_sym
    minutes_ago(::Settings.performance.capture_threshold_with_alerts[target_key] ||
                ::Settings.performance.capture_threshold_with_alerts.default)
  end

  def self.perf_capture_timer(ems_id)
    _log.info("Queueing performance capture...")

    ems = ExtManagementSystem.find(ems_id)
    pco = ems.perf_capture_object
    zone = ems.zone
    pco.send(:perf_capture_health_check)
    targets = Metric::Targets.capture_ems_targets(ems)

    targets_by_rollup_parent = pco.send(:calc_targets_by_rollup_parent, targets)
    target_options = pco.send(:calc_target_options, targets_by_rollup_parent)
    targets = pco.send(:filter_perf_capture_now, targets, target_options)
    pco.queue_captures(targets, target_options)

    # Purge tasks older than 4 hours
    MiqTask.delete_older(4.hours.ago.utc, "name LIKE 'Performance rollup for %'")

    _log.info("Queueing performance capture...Complete")
  end

  def self.perf_capture_gap(start_time, end_time, zone_id = nil, ems_id = nil)
    raise ArgumentError, "end_time and start_time must be specified" if start_time.nil? || end_time.nil?
    raise _("Start time must be earlier than End time") if start_time > end_time

    _log.info("Queueing performance capture for range: [#{start_time} - #{end_time}]...")

    emses = if ems_id
              [ExtManagementSystem.find(ems_id)]
            elsif zone_id
              Zone.find(zone_id).ems_metrics_collectable
            else
              MiqServer.my_server.zone.ems_metrics_collectable
            end
    emses.each do |ems|
      pco = ems.perf_capture_object
      targets = Metric::Targets.capture_ems_targets(ems, :exclude_storages => true)
      target_options = Hash.new { |_n, _v| {:start_time => start_time.utc, :end_time => end_time.utc, :zone => ems.zone, :interval => 'historical'} }
      pco.queue_captures(targets, target_options)
    end

    _log.info("Queueing performance capture for range: [#{start_time} - #{end_time}]...Complete")
  end

  # called by the UI
  # @param zone [Zone] zone where the ems resides
  # @param ems [ExtManagementSystem] ems to capture collect
  #
  # pass at least one of these, since we need to specify which ems needs a gap to run
  # Prefer to use the ems over the zone for perf_capture_gap
  def self.perf_capture_gap_queue(start_time, end_time, zone, ems = nil)
    zone ||= ems.zone

    MiqQueue.put(
      :class_name  => name,
      :method_name => "perf_capture_gap",
      :role        => "ems_metrics_coordinator",
      :priority    => MiqQueue::HIGH_PRIORITY,
      :zone        => zone.name,
      :args        => [start_time, end_time, zone.id, ems&.id]
    )
  end

  def self.minutes_ago(value)
    if value.kind_of?(Integer) # Default unit is minutes
      value.minutes.ago.utc
    elsif value.nil?
      nil
    else
      value.to_i_with_method.seconds.ago.utc
    end
  end
  private_class_method :minutes_ago
end
