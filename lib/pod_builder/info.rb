require 'cfpropertylist'

module PodBuilder
  class Info
    def self.generate_info
      restore_path = PodBuilder::basepath("Podfile.restore")
      unless File.exist?(restore_path)
        raise "No Podfile.restore file found"
        return false
      end
      
      podspec_path = PodBuilder::basepath("PodBuilder.podspec")
      unless File.exist?(podspec_path)
        raise "No PodBuilder.podspec file found"
        return false
      end
      
      restore_content = File.read(restore_path)
      
      swift_version = PodBuilder::system_swift_version
      result = {}
      podbuilder_name = nil
      File.read(podspec_path).each_line do |line|
        if (matches = line.match(/s.subspec '(.*)' do \|p\|/)) && matches.size == 2
          podbuilder_name = matches[1]
        elsif (matches = line.match(/p.vendored_frameworks = '(.*)'/)) && matches.size == 2
          path = matches[1].split("'").first
          plist_path = File.join(PodBuilder::basepath(path), Configuration.framework_plist_filename)
          
          name = podbuilder_name
          
          # check if it's a subspec
          if (subspec_items = podbuilder_name.split("_")) && (subspec = subspec_items.last) && subspec_items.count > 1
            if path.include?("/#{subspec}")
              name = podbuilder_name.sub(/_#{subspec}$/, "/#{subspec}")
            end
          end
          result[name] = { "podbuilder_name": podbuilder_name, framework_path: path }

            raise "pod `#{name}` not found in restore file"
          end
          restore_line = restore_line(name, restore_content)
          version = version_info(restore_line)
          result[name].merge!({ "version": version })
          
          prebuilt_info = prebuilt_info(plist_path)
          if prebuilt_info.count > 0 
            result[name].merge!({ "prebuilt_info": prebuilt_info })
          end
        end
      end

      return result
    end
    
    private
    
    def self.version_info(line)
      if (matches = line&.match(/pod '(.*)', '=(.*)'/)) && matches.size == 3
        pod_name = matches[1]
        tag = matches[2]
        
        return { "tag": tag }
      elsif (matches = line&.match(/pod '(.*)', :git => '(.*)', :commit => '(.*)'/)) && matches.size == 4
        pod_name = matches[1]
        repo = matches[2]
        hash = matches[3]
        
        return { "repo": repo, "hash": hash }
      elsif (matches = line&.match(/pod '(.*)', :git => '(.*)', :branch => '(.*)'/)) && matches.size == 4
        pod_name = matches[1]
        repo = matches[2]
        branch = matches[3]
        
        return { "repo": repo, "branch": branch }
      elsif (matches = line&.match(/pod '(.*)', :git => '(.*)', :tag => '(.*)'/)) && matches.size == 4
        pod_name = matches[1]
        repo = matches[2]
        tag = matches[3]
        
        return { "repo": repo, "tag": tag }
      else
        raise "Failed extracting version from line:\n#{line}\n\n"
      end
    end
    
    def self.prebuilt_info(path)
      unless File.exist?(path)
        return {}
      end
      
      plist = CFPropertyList::List.new(:file => path)
      data = CFPropertyList.native_types(plist.value)
      
      result = {}
      if swift_version = data["swift_version"]
        result.merge!({ "swift_version": swift_version})
      end
      
      pod_version = version_info(data["entry"])
      
      result.merge!({ "version": pod_version })
      result.merge!({ "specs": data["specs"] })
      
      return result
    end

    def self.restore_line(name, restore_content)
      unless (matches = restore_content.match(/pod '#{name}(\/.*)?'.*/)) && matches.size == 2
        raise "pod `#{name}` not found in restore file"
      end
      return matches[0]
    end
  end
end