require "xcodeproj"
require "pod_builder/core"
require "digest"

# Skip warning
Pod::Installer::Xcode::TargetValidator.send(:define_method, :verify_no_duplicate_framework_and_library_names) { }

# workaround for https://github.com/CocoaPods/CocoaPods/issues/3289
Pod::Installer::Xcode::TargetValidator.send(:define_method, :verify_no_static_framework_transitive_dependencies) { }

# The following begin/end clause contains a set of monkey patches of the original CP implementation

# The Pod::Target and Pod::Installer::Xcode::PodTargetDependencyInstaller swizzles patch
# the following issues:
# - https://github.com/CocoaPods/Rome/issues/81
# - https://github.com/leavez/cocoapods-binary/issues/50
begin
  require "cocoapods/installer/xcode/pods_project_generator/pod_target_dependency_installer.rb"

  class Pod::Specification
    Pod::Specification.singleton_class.send(:alias_method, :swz_from_hash, :from_hash)
    Pod::Specification.singleton_class.send(:alias_method, :swz_from_string, :from_string)

    def self.from_string(*args)
      spec = swz_from_string(*args)

      if overrides = PodBuilder::Configuration.spec_overrides[spec.name]
        overrides.each do |k, v|
          if spec.attributes_hash[k].is_a?(Hash)
            current = spec.attributes_hash[k]
            spec.attributes_hash[k] = current.merge(v)
          else
            spec.attributes_hash[k] = v
          end
        end
      end

      spec
    end
  end

  class Pod::Target
    attr_accessor :mock_dynamic_framework

    alias_method :swz_build_type, :build_type

    def build_type
      if mock_dynamic_framework == true
        if defined?(Pod::BuildType) # CocoaPods 1.9 and later
          Pod::BuildType.new(linkage: :dynamic, packaging: :framework)
        elsif defined?(Pod::Target::BuildType) # CocoaPods 1.7, 1.8
          Pod::Target::BuildType.new(linkage: :dynamic, packaging: :framework)
        else
          raise "\n\nBuildType not found. Open an issue reporting your CocoaPods version\n".red
        end
      else
        swz_build_type()
      end
    end
  end

  class Pod::PodTarget
    @@modules_override = Hash.new

    def self.modules_override=(x)
      @@modules_override = x
    end

    def self.modules_override
      return @@modules_override
    end

    alias_method :swz_defines_module?, :defines_module?

    def defines_module?
      return @@modules_override.has_key?(name) ? @@modules_override[name] : swz_defines_module?
    end
  end

  # Starting from CocoaPods 1.10.0 and later resources are no longer copied inside the .framework
  # when building static frameworks. While this is correct when using CP normally, for redistributable
  # frameworks we require resources to be shipped along the binary
  class Pod::Installer::Xcode::PodsProjectGenerator::PodTargetInstaller
    alias_method :swz_add_files_to_build_phases, :add_files_to_build_phases

    def add_files_to_build_phases(native_target, test_native_targets, app_native_targets)
      target.mock_dynamic_framework = target.build_as_static_framework?
      swz_add_files_to_build_phases(native_target, test_native_targets, app_native_targets)
      target.mock_dynamic_framework = false
    end
  end

  class Pod::Installer::Xcode::PodTargetDependencyInstaller
    alias_method :swz_wire_resource_bundle_targets, :wire_resource_bundle_targets

    def wire_resource_bundle_targets(resource_bundle_targets, native_target, pod_target)
      pod_target.mock_dynamic_framework = pod_target.build_as_static_framework?
      res = swz_wire_resource_bundle_targets(resource_bundle_targets, native_target, pod_target)
      pod_target.mock_dynamic_framework = false
      return res
    end
  end
rescue LoadError
  # CocoaPods 1.6.2 or earlier
end

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
    raise "\n\nUnsupported CocoaPods version\n".red if (args.count == 0 || args.count > 2)

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
