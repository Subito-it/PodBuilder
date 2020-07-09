require 'cfpropertylist'

module PodBuilder
  class Info
    def self.generate_info
      swift_version = PodBuilder::system_swift_version
      result = {}
      name = nil

      Dir.glob(PodBuilder::prebuiltpath("**/*.framework")).each do |path|
        plist_path = File.join(path, Configuration.framework_plist_filename)

        name, prebuilt_info = prebuilt_info(plist_path)
        result[name] = prebuilt_info
      end

      return result
    end
    
    private

    def self.pod_name_from_entry(line)
      if (matches = line&.match(/pod '(.*?)'/)) && matches.size == 2
        pod_name = matches[1]
        
        return pod_name
      end

      return "unknown_podname"
    end
    
    def self.version_info_from_entry(line)
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
      elsif (matches = line&.match(/pod '(.*)', :path => '(.*)'/)) && matches.size == 3
        pod_name = matches[1]
        
        return { "repo": "local" }
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
      
      pod_version = version_info_from_entry(data["entry"])
      pod_name = pod_name_from_entry(data["entry"])

      
      result.merge!({ "version": pod_version })
      result.merge!({ "specs": (data["specs"] || []) })
      result.merge!({ "is_static": (data["is_static"] || false) })
      result.merge!({ "original_compile_path": (data["original_compile_path"] || "") })
      
      return pod_name, result
    end    
  end
end