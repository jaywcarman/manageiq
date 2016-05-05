module Metric::Targets
  cache_with_timeout(:perf_capture_always, 1.minute) do
    MiqRegion.my_region.perf_capture_always
  end

  def self.perf_capture_always=(options)
    perf_capture_always_clear_cache
    MiqRegion.my_region.perf_capture_always = options
  end

  def self.capture_infra_targets(zone, options)
    # Preload all of the objects we are going to be inspecting.
    includes = {:ext_management_systems => {:hosts => {:ems_cluster => :tags, :tags => {}}}}
    includes[:ext_management_systems][:hosts][:storages] = :tags unless options[:exclude_storages]
    MiqPreloader.preload(zone, includes)

    targets = zone.hosts
    targets += zone.storages.select { |s| Storage::SUPPORTED_STORAGE_TYPES.include?(s.store_type) } unless options[:exclude_storages]

    # If it can and does have a cluster, then ask that, otherwise, ask host itself.
    targets = targets.select do |t|
      t.respond_to?(:ems_cluster) && t.ems_cluster ? t.ems_cluster.perf_capture_enabled? : t.perf_capture_enabled?
    end

    targets += capture_vm_targets(targets, Host, options)

    targets
  end

  # @return vms under all availability zones
  #         and vms under no availability zone
  # NOTE: some stacks (e.g. nova) default to no availability zone
  def self.capture_cloud_targets(zone, options = {})
    return [] if options[:exclude_vms]

    includes = {:availability_zones => [:tags, {:vms => :ext_management_system}], :vms => :availability_zone }
    MiqPreloader.preload(zone.ems_clouds, includes)

    availability_zones = zone.ems_clouds.flat_map(&:availability_zones)
    enabled_parents = availability_zones.select { |t| t.perf_capture_enabled? }
    vms_with_availability_zone = enabled_parents.flat_map { |t| t.vms.select { |v| v.state == 'on' } }

    vms_without_availability_zone = zone.ems_clouds.flat_map { |e| e.vms.select { |vm| vm.availability_zone.nil? } }

    vms_with_availability_zone + vms_without_availability_zone
  end

  def self.capture_container_targets(zone, _options)
    includes = {
      :container_nodes  => :tags,
      :container_groups => [:tags, :containers => :tags],
    }

    MiqPreloader.preload(zone.ems_containers, includes)

    targets = []
    zone.ems_containers.each do |ems|
      targets += ems.container_nodes
      targets += ems.container_groups
      targets += ems.container_groups.flat_map(&:containers)
    end

    targets
  end

  def self.capture_vm_targets(targets, parent_class, options)
    vms = []
    unless options[:exclude_vms]
      enabled_parents = targets.select do |t|
        t.kind_of?(parent_class) &&
        t.kind_of?(Metric::CiMixin) &&
        t.perf_capture_enabled? &&
        t.respond_to?(:vms)
      end
      MiqPreloader.preload(enabled_parents, :vms => :ext_management_system)
      vms = targets.flat_map { |t| enabled_parents.include?(t) ? t.vms.select { |v| v.state == 'on' } : [] }
    end
    vms
  end

  # If a Cluster, standalone Host, or Storage is not enabled, skip it.
  # If a Cluster is enabled, capture all of its Hosts.
  # If a Host is enabled, capture all of its Vms.
  def self.capture_targets(zone = nil, options = {})
    zone = MiqServer.my_server.zone if zone.nil?
    zone = Zone.find(zone) if zone.kind_of?(Integer)
    capture_infra_targets(zone, options) + \
      capture_cloud_targets(zone, options) + \
      capture_container_targets(zone, options)
  end
end
