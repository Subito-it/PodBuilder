require 'cocoapods/podfile.rb'

module Pod
  class Podfile
    class TargetDefinition
      def pb_to_s(all_buildable_items, indent_level = 0, parent_pods = [])
        indentation = "  " * indent_level
        target_s = "#{indentation}target '#{self.name}' do\n"
        
        child_indentation = "  " * (indent_level + 1)

        explicit_deps = self.dependencies.map { |t| all_buildable_items.detect { |u| u.name == t.name } }.compact
        
        pod_entries = []
        prebuild_entries = []
        self.dependencies.each do |dep|
          if podfile_item = all_buildable_items.detect { |t| t.name == dep.name } 
            is_prebuilt = all_buildable_items.select { |t| t.root_name == dep.root_name}.all?(&:is_prebuilt)
            if File.exist?(podfile_item.prebuilt_podspec_path) && !is_prebuilt
              prebuild_entries.push(podfile_item)
            else
              pod_entries.push(podfile_item)
            end

            non_explicit_dependencies = podfile_item.recursive_dependencies(all_buildable_items) - explicit_deps
            non_explicit_dependencies_root_names = non_explicit_dependencies.map(&:root_name).uniq.filter { |t| t != podfile_item.root_name }
            non_explicit_dependencies = non_explicit_dependencies_root_names.map { |x| 
              if item = all_buildable_items.detect { |t| x == t.name }
                item                    
              else
                item = all_buildable_items.detect { |t| x == t.root_name }
              end
            }.compact
            
            non_explicit_dependencies.each do |dep|
              dep_item = all_buildable_items.detect { |x| x.name == dep.name }

              is_prebuilt = all_buildable_items.select { |t| t.root_name == dep.root_name}.all?(&:is_prebuilt)
              if File.exist?(dep_item.prebuilt_podspec_path) && !is_prebuilt
                prebuild_entries.push(dep_item)
              else
                pod_entries.push(dep_item)
              end

              explicit_deps.push(dep)
            end       
          end
        end

        prebuild_entries = prebuild_entries.uniq.sort_by { |t| t.name }
        pod_entries = pod_entries.uniq.sort_by { |t| t.name }
        
        # Don't include inherited pods
        prebuild_entries.reject! { |t| parent_pods.include?(t) }
        pod_entries.reject! { |t| parent_pods.include?(t) }

        prebuild_entries.each do |pod|
          target_s += "#{child_indentation}#{pod.prebuilt_entry(false, false)}\n"
        end
        pod_entries.each do |pod|
          target_s += "#{child_indentation}#{pod.entry(true, false)}\n"
        end

        if self.children.count > 0
          target_s += "\n"
          target_s += @children.map { |t| t.pb_to_s(all_buildable_items, indent_level + 1, parent_pods + pod_entries + prebuild_entries) }.join("\n\n")
        end

        target_s += "#{indentation}end\n"
      end
    end
  end
end

module Pod
  class Podfile
    def pb_to_s(all_buildable_items)
      initial_targets = root_target_definitions.first.children
      
      platform = @current_target_definition.platform
      
      podfile_s = "platform :#{platform.to_sym}, '#{platform.deployment_target.to_s}'\n\n"
      podfile_s += initial_targets.map { |t| t.pb_to_s(all_buildable_items) }.join("\n\n")

      return podfile_s
    end
  end
end

class PodfileCP
  def self.podfile_path_transform(path)
    prebuilt_prefix = PodBuilder::prebuiltpath.gsub(PodBuilder::project_path, "")[1..] + "/"
    if path.start_with?(prebuilt_prefix)
      return path
    else
      return PodBuilder::Podfile.podfile_path_transform(path)
    end
  end
end