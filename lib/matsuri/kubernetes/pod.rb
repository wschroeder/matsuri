require 'active_support/core_ext/hash/compact'
require 'active_support/core_ext/object/blank'
require 'json'

# rubocop:disable Lint/MissingCopEnableDirective
# rubocop:disable Style/Alias
module Matsuri
  module Kubernetes
    class Pod < Matsuri::Kubernetes::Base
      let(:api_version) { 'v1' }
      let(:kind)        { 'Pod' }

      # Overridables
      let(:spec) do
        {
          hostname:   hostname,
          subdomain:  subdomain,
          containers: containers,
          volumes:    volumes,
          imagePullSecrets: image_pull_secrets,
          nodeSelector: node_selector,
          affinity: affinity,
          tolerations: tolerations
        }.compact
      end

      # Get image tag from the command line
      let(:image_tag)          { options[:image_tag] || 'latest' }

      let(:containers)         { [container] }
      let(:volumes)            { [volume] }
      let(:image_pull_secrets) { [] }
      let(:tolerations)        { [toleration].compact }
      let(:toleration)         { nil }
      let(:affinity)           { { nodeAffinity: node_affinity, podAffinity: pod_affinity, podAntiAffinity: pod_anti_affinity }.compact }
      let(:node_affinity)      { nil } # https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.10/#nodeaffinity-v1-core
      let(:pod_affinity)       { nil } # https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.10/#podaffinity-v1-core
      let(:pod_anti_affinity)  { nil } # https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.10/#podantiaffinity-v1-core
      let(:hostname)           { nil } # https://kubernetes.io/docs/admin/dns/
      let(:subdomain)          { nil }
      let(:resources)          { { requests: resource_requests, limits: resource_limits } }
      let(:resource_requests)  { { cpu: cpu_request, memory: mem_request }.compact }
      let(:resource_limits)    { { cpu: cpu_limit,   memory: mem_limit  }.compact }

      let(:node_selector)      { { } }

      let(:container)   { fail NotImplementedError, 'Must define let(:container)'}
      let(:volume)      { fail NotImplementedError, 'Must define let(:volume)' }

      let(:primary_container) { containers.first[:name] }
      let(:primary_image)     { fail NotImplementedError, 'Must define let(:primary_image) for deployment or replication controller' }

      # We want to make sure all limits are defined
      let(:cpu_limit)   { fail NotImplementedError, 'Must define let(:cpu_limit)' }
      let(:mem_limit)   { fail NotImplementedError, 'Must define let(:mem_limit)' }
      let(:cpu_request) { cpu_limit }
      let(:mem_request) { cpu_limit }

      # Pods are practically useless with using apply. When we converge, we want
      # to recreate instead. Pods unamaged by rc, rs, or deployment are more useful
      # in dev mode than anywhere else
      def converge!(opts = {})
        converge_by_recreate!(opts)
      end

      # Helper methods
      def up?
        cmd = kubectl "get #{resource_type}/#{name} -o json", echo_level: :debug, no_stdout: true
        Matsuri.log :fatal, "Unable to get status for #{resource_type}/#{name}" unless cmd.status.success?
        pod_json = JSON.parse(cmd.stdout)
        Matsuri.log :debug, pod_json['status']
        return false unless pod_json['status']['phase'] == 'Running'
        return false unless pod_json['status']['containerStatuses'].any?
        pod_json['status']['containerStatuses'].all? { |c| c['ready'] == true }
      end

      def config_file(path)
        File.join config.config_path, path
      end

      def cache_path(path)
        File.join config.cache_path, path
      end

      def src_path(path)
        File.join config.src_path, path
      end

      def base_path(path)
        File.join config.base_path, path
      end

      # Ruby 2.0+ uses ordered hashes
      def expand_env(hash)
        hash.map do |k,v|
          if v.is_a?(Hash)
            { name: k, valueFrom: v }
          else
            { name: k, value: v.to_s }
          end
        end
      end

      def env_from_secret(name:, key:)
        { secretKeyRef: { name: name, key: key } }
      end

      def env_from_config_map(name:, key:)
        { configMapKeyRef: { name: name, key: key } }
      end

      def evn_from_field_ref(path:)
        { fieldRef: { fieldPath: path } }
      end

      def sorted_env(hash)
        expand_env(hash).sort { |a,b| a[:name] <=> b[:name] }
      end

      def port(num, protocol: 'TCP', name: nil)
        _port = { containerPort: num, protocol: protocol.to_s }
        _port[:name] = name.to_s if name
        return _port
      end

      def mount(name, path, read_only: false)
        { name: name, mountPath: path, readOnly: read_only }
      end

      def host_path_volume(name, host_path)
        { name: name, hostPath: { path: host_path } }
      end

      def empty_dir_volume(name)
        { name: name, emptyDir: {} }
      end

      def secret_volume(name, secret_name:)
        { name: name, secret: { secretName: secret_name } }
      end

      def config_map_volume(name, config_map_name: nil, items: nil, default_mode: nil)
        config_map_name ||= name
        { name: name, configMap: { name: config_map_name, items: items, defaultMode: default_mode }.compact }
      end

      def gce_volume(name, pd_name:, fs_type: 'ext4')
        { name: name, gcePersistentDisk: { pdName: pd_name, fsType: fs_type } }
      end

      def label_selector(match_labels: nil, match_expressions: nil)
        {
          matchLabels:      match_labels,
          matchExpressions: match_expressions.present? ? Array(match_expressions) : nil
        }
      end

      def match_expression(key:, operator:, values: nil)
        { key: key, operator: operator, values: values }.compact
      end

      def tolerate(key: nil, value: nil, operator: 'Equal', effect: nil, toleration_seconds: nil)
        {
          key:               key,
          value:             value,
          effect:            effect,
          operator:          operator,
          tolerationSeconds: toleration_seconds
        }.compact
      end

      # Helper to generate pod affinity term
      # Defaults to node name for topology key, and empty namespaces
      def pod_affinity_term(match_labels: nil, match_expressions: nil, namespaces: [], topology_key: 'kubernetes.io/hostname')
        {
          labelSelector: label_selector(match_labels: match_labels, match_expressions: match_expressions),
          namespaces:    namespaces,
          topologyKey:   topology_key
        }.compact
      end

      alias_method :affinity_term, :pod_affinity_term

      def weighted_pod_affinity_term(weight: 100, match_labels: nil, match_expressions: nil, namespaces: [], topology_key: 'kubernetes.io/hostname')
        {
          weight: weight,
          podAffinityTerm: pod_affinity_term(match_labels: match_labels, match_expressions: match_expressions, namespaces: namespaces, topology_key: topology_key)
        }
      end

      alias_method :weighted_affinity_term, :weighted_pod_affinity_term

      def preferred_during_scheduling_ignored_during_execution(*weighted_affinity_terms)
        { preferredDuringSchedulingIgnoredDuringExecution: weighted_affinity_terms }
      end

      alias_method :preferred_during_scheduling, :preferred_during_scheduling_ignored_during_execution

      def required_during_scheduling_ignored_during_execution(*affinity_terms)
        { requiredDuringSchedulingIgnoredDuringExecution: affinity_terms }
      end

      alias_method :required_during_scheduling, :required_during_scheduling_ignored_during_execution

      # Helpers

      def diff!(opt = {})
        deltas = opt[:primary_container] ? primary_container_diff : diff
        print_diff(deltas)
      end

      def containers_diff
        current = current_manifest(raw: true)
        Matsuri.log :fatal, "Cannot fetch current manifest for #{resource_type}/#{name}" unless current

        desired = JSON.parse(to_json)

        HashDiff.diff current['spec']['containers'][0], desired['spec']['containers'][0]
      end

      class << self
        def load_path
          Matsuri::Config.pods_path
        end

        def definition_module_name
          'Pods'
        end
      end
    end
  end
end
