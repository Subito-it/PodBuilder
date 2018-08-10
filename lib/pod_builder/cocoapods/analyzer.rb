module Pod
  class Installer
    class Analyzer
      def pods_and_deps_in_target(target_name, podfile_items)
        target_name = "Pods-#{target_name}"

        specs = result.specs_by_target.select { |key, value| key.label == target_name }.values.first
        specs.select! { |x| podfile_items.map(&:name).include?(x.name) }
        
        target_pods = []
        specs.each do |spec|
          pod = podfile_items.detect { |x| x.name == spec.name }
          raise "Pod #{spec.name} not found while trying to build Podfile.restore!" if pod.nil?
          target_pods.push(pod)
        end

        target_dependencies = target_pods.map { |x| x.dependencies(podfile_items) }.flatten.uniq
        target_pods -= target_dependencies

        return target_pods.uniq, target_dependencies.uniq
      end
    end
  end
end