require 'xcodeproj'
require 'pod_builder/core'
require 'digest'

class Pod::Generator::FileList
  alias_method :swz_initialize, :initialize
  
  def initialize(paths)
    paths.uniq!
    swz_initialize(paths)
  end
end 

class Pod::Generator::CopyXCFrameworksScript
  alias_method :swz_initialize, :initialize
  
  def initialize(xcframeworks, sandbox_root, platform)
    xcframeworks.uniq! { |t| t.path }
    swz_initialize(xcframeworks, sandbox_root, platform)
  end
end 

class Pod::Generator::EmbedFrameworksScript
  alias_method :swz_initialize, :initialize
  
  def initialize(*args)
    raise "Unsupported CocoaPods version" if (args.count == 0 || args.count > 2)
    
    frameworks_by_config = args[0]
    frameworks_by_config.keys.each do |key|
      items = frameworks_by_config[key]
      items.uniq! { |t| t.source_path }
      frameworks_by_config[key] = items
    end

    if args.count == 2
      # CocoaPods 1.10.0 and newer
      xcframeworks_by_config = args[1]
      xcframeworks_by_config.keys.each do |key|
        items = xcframeworks_by_config[key]
        items.uniq! { |t| t.path }
        xcframeworks_by_config[key] = items
      end
    end

    swz_initialize(*args)
  end
end 

class Pod::Generator::CopyResourcesScript
  alias_method :swz_initialize, :initialize
  
  def initialize(resources_by_config, platform)
    resources_by_config.keys.each do |key|
      items = resources_by_config[key]
      items.uniq!

      colliding_resources = items.group_by { |t| File.basename(t) }.values.select { |t| t.count > 1 }

      unless colliding_resources.empty?
        message = ""
        colliding_resources.each do |resources|
          resources.map! { |t| File.expand_path(t.gsub("${PODS_ROOT}", "#{Dir.pwd}/Pods")) }
          # check that files are identical. 
          # For files with paths that are resolved (e.g containing ${PODS_ROOT}) we use the file hash
          # we fallback to the filename for the others
          hashes = resources.map { |t| File.exists?(t) ? Digest::MD5.hexdigest(File.read(t)) : File.basename(t) }
          if hashes.uniq.count > 1
            message += resources.join("\n") + "\n"
          end
        end

        unless message.empty?
          message = "\n\nThe following resources have the same name and will collide once copied into application bundle:\n" + message
          raise message
        end
      end

      resources_by_config[key] = items
    end
    
    swz_initialize(resources_by_config, platform)
  end
end 
