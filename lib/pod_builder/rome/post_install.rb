require "fourflusher"
require "colored"
require "pathname"

module PodBuilder
  class XcodeBuildSettings
    attr_reader :platform_name
    attr_reader :build_destination
    attr_reader :configuration

    def initialize(platform_name, configuration)
      @platform_name = platform_name
      @configuration = configuration

      case platform_name
      when "iphoneos" then @build_destination = "generic/platform=iOS"
      when "iphonesimulator" then @build_destination = "generic/platform=iOS Simulator"
      when "catalyst" then @build_destination = "platform=macOS,arch=x86_64,variant=Mac Catalyst"
      when "macos" then @build_destination = "generic/platform=OS X"
      when "tvos" then @build_destination = "generic/platform=tvOS"
      when "tvossimulator" then @build_destination = "generic/platform=tvOS Simulator"
      when "watchos" then @build_destination = "generic/platform=watchOS"
      when "watchossimulator" then @build_destination = "generic/platform=watchOS Simulator"
      else raise "\n\nUnknown platform '#{platform_name}'\n".red
      end
    end
  end

  def self.build_for_iosish_platform_framework(sandbox, build_dir, target, device, simulator, configuration, deterministic_build)
    dsym_device_folder = File.join(build_dir, "dSYM", device)
    dsym_simulator_folder = File.join(build_dir, "dSYM", simulator)
    FileUtils.mkdir_p(dsym_device_folder)
    FileUtils.mkdir_p(dsym_simulator_folder)

    deployment_target = target.platform_deployment_target
    target_label = target.cocoapods_target_label

    xcodebuild(sandbox, target_label, device, deployment_target, configuration, deterministic_build, [], {})
    excluded_archs = ["i386"] # Fixes https://github.com/Subito-it/PodBuilder/issues/17
    excluded_archs += ["arm64"] # Exclude apple silicon slice
    xcodebuild(sandbox, target_label, simulator, deployment_target, configuration, deterministic_build, excluded_archs, {})

    spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
    spec_names.each do |root_name, module_name|
      device_base = "#{build_dir}/#{configuration}-#{device}/#{root_name}"
      device_lib = "#{device_base}/#{module_name}.framework/#{module_name}"
      device_dsym = "#{device_base}/#{module_name}.framework.dSYM"
      device_framework_lib = File.dirname(device_lib)
      device_swift_header_path = "#{device_framework_lib}/Headers/#{module_name}-Swift.h"

      simulator_base = "#{build_dir}/#{configuration}-#{simulator}/#{root_name}"
      simulator_lib = "#{simulator_base}/#{module_name}.framework/#{module_name}"
      simulator_dsym = "#{simulator_base}/#{module_name}.framework.dSYM"
      simulator_framework_lib = File.dirname(simulator_lib)
      simulator_swift_header_path = "#{simulator_framework_lib}/Headers/#{module_name}-Swift.h"

      next unless File.file?(device_lib) && File.file?(simulator_lib)

      # Starting with Xcode 12b3 the simulator binary contains an arm64 slice as well which conflict with the one in the device_lib
      # when creating the fat library. A naive workaround is to remove the arm64 from the simulator_lib however this is wrong because
      # we might actually need to have 2 separated arm64 slices, one for simulator and one for device each built with different
      # compile time directives (e.g #if targetEnvironment(simulator))
      #
      # For the time being we remove the arm64 slice bacause otherwise the `xcrun lipo -create -output ...` would fail.
      if `xcrun lipo -info #{simulator_lib}`.include?("arm64")
        `xcrun lipo -remove arm64 #{simulator_lib} -o #{simulator_lib}`
      end

      raise "\n\nLipo failed on #{device_lib}\n".red unless system("xcrun lipo -create -output #{device_lib} #{device_lib} #{simulator_lib}")

      merge_header_into(device_swift_header_path, simulator_swift_header_path)

      # Merge device framework into simulator framework (so that e.g swift Module folder is merged)
      # letting device framework files overwrite simulator ones
      FileUtils.cp_r(File.join(device_framework_lib, "."), simulator_framework_lib)
      source_lib = File.dirname(simulator_framework_lib)

      FileUtils.mv(device_dsym, dsym_device_folder) if File.exist?(device_dsym)
      FileUtils.mv(simulator_dsym, dsym_simulator_folder) if File.exist?(simulator_dsym)

      FileUtils.mv(source_lib, build_dir)

      # Remove frameworks leaving dSYMs
      FileUtils.rm_rf(device_framework_lib)
      FileUtils.rm_rf(simulator_framework_lib)
    end
  end

  def self.build_for_iosish_platform_lib(sandbox, build_dir, target, device, simulator, configuration, deterministic_build, prebuilt_root_paths)
    deployment_target = target.platform_deployment_target
    target_label = target.cocoapods_target_label

    spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq

    xcodebuild(sandbox, target_label, device, deployment_target, configuration, deterministic_build, [], prebuilt_root_paths)
    excluded_archs = ["arm64"] # Exclude Apple silicon slice
    xcodebuild(sandbox, target_label, simulator, deployment_target, configuration, deterministic_build, excluded_archs, prebuilt_root_paths)

    spec_names.each do |root_name, module_name|
      simulator_base = "#{build_dir}/#{configuration}-#{simulator}/#{root_name}"
      simulator_lib = "#{simulator_base}/lib#{root_name}.a"

      device_base = "#{build_dir}/#{configuration}-#{device}/#{root_name}"
      device_lib = "#{device_base}/lib#{root_name}.a"

      unless File.file?(device_lib) && File.file?(simulator_lib)
        next
      end

      # Starting with Xcode 12b3 the simulator binary contains an arm64 slice as well which conflict with the one in the device_lib
      # when creating the fat library. A naive workaround is to remove the arm64 from the simulator_lib however this is wrong because
      # we might actually need to have 2 separated arm64 slices, one for simulator and one for device each built with different
      # compile time directives (e.g #if targetEnvironment(simulator))
      #
      # For the time being we remove the arm64 slice bacause otherwise the `xcrun lipo -create -output ...` would fail.
      if `xcrun lipo -info #{simulator_lib}`.include?("arm64")
        `xcrun lipo -remove arm64 #{simulator_lib} -o #{simulator_lib}`
      end

      raise "\n\nLipo failed on #{device_lib}\n".red unless system("xcrun lipo -create -output #{device_lib} #{device_lib} #{simulator_lib}")

      device_headers = Dir.glob("#{device_base}/**/*.h")
      simulator_headers = Dir.glob("#{simulator_base}/**/*.h")
      device_headers.each do |device_path|
        simulator_path = device_path.gsub(device_base, simulator_base)

        merge_header_into(device_path, simulator_path)
      end
      simulator_only_headers = simulator_headers - device_headers.map { |t| t.gsub(device_base, simulator_base) }
      simulator_only_headers.each do |path|
        add_simulator_conditional(path)
        dir_name = File.dirname(path)
        destination_folder = dir_name.gsub(simulator_base, device_base)
        FileUtils.mkdir_p(destination_folder)
        FileUtils.cp(path, destination_folder)
      end

      swiftmodule_path = "#{simulator_base}/#{root_name}.swiftmodule"
      if File.directory?(swiftmodule_path)
        FileUtils.cp_r("#{swiftmodule_path}/.", "#{device_base}/#{root_name}.swiftmodule")
      end

      if File.exist?("#{device_base}/#{root_name}.swiftmodule")
        # This is a swift pod with a swiftmodule in the root of the prebuilt folder
      else
        # Objective-C pods have the swiftmodule generated under Pods/Headers/Public
        public_headers_path = "#{Configuration.build_path}/Pods/Headers/Public/#{root_name}"
        module_public_headers_path = "#{Configuration.build_path}/Pods/Headers/Public/#{module_name}"
        if public_headers_path.downcase != module_public_headers_path.downcase && File.directory?(public_headers_path) && File.directory?(module_public_headers_path)
          # For pods with module_name != name we have to move the modulemap files to the root_name one
          module_public_headers_path = "#{Configuration.build_path}/Pods/Headers/Public/#{module_name}"
          FileUtils.cp_r("#{module_public_headers_path}/.", public_headers_path, :remove_destination => true)
        end
        Dir.glob("#{public_headers_path}/**/*.*").each do |path|
          destination_folder = "#{device_base}/Headers" + path.gsub(public_headers_path, "")
          destination_folder = File.dirname(destination_folder)
          FileUtils.mkdir_p(destination_folder)
          FileUtils.cp(path, destination_folder)
        end
      end

      destination_path = "#{build_dir}/#{root_name}"
      if Dir.glob("#{device_base}/**/*.{a,framework,h}").count > 0
        FileUtils.mv(device_base, destination_path)

        module_maps = Dir.glob("#{destination_path}/**/*.modulemap")
        module_map_device_base = device_base.gsub(/^\/private/, "") + "/"
        module_maps.each do |module_map|
          content = File.read(module_map)
          content.gsub!(module_map_device_base, "")
          File.write(module_map, content)
        end
      end
    end
  end

  def self.merge_header_into(device_file, simulator_file)
    unless File.exist?(device_file) || File.exist?(simulator_file)
      return
    end

    device_content = File.file?(device_file) ? File.read(device_file) : ""
    simulator_content = File.file?(simulator_file) ? File.read(simulator_file) : ""
    merged_content = %{
      #if TARGET_OS_SIMULATOR
      // ->
      
      #{simulator_content}
      
      // ->
      #else
      // ->
      
      #{device_content}
      
      // ->
      #endif
    }
    File.write(device_file, merged_content)
  end

  def self.add_simulator_conditional(path)
    file_content = File.read(path)
    content = %{
      #if TARGET_OS_SIMULATOR
      #{file_content}
      #endif
    }
    File.write(path, content)
  end

  def self.xcodebuild(sandbox, target, sdk = "macosx", deployment_target = nil, configuration, deterministic_build, exclude_archs, prebuilt_root_paths)
    args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target} -configuration #{configuration} -sdk #{sdk})
    supported_platforms = { "iphonesimulator" => "iOS", "appletvsimulator" => "tvOS", "watchsimulator" => "watchOS" }
    if platform = supported_platforms[sdk]
      args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?
    end

    xcodebuild_version = `xcodebuild -version | head -n1 | awk '{print $2}'`.strip().to_f
    if exclude_archs.count > 0 && xcodebuild_version >= 12.0
      args += ["EXCLUDED_ARCHS=#{exclude_archs.join(" ")}"]
    end
    prebuilt_root_paths.each do |k, v|
      args += ["#{k.upcase.gsub("-", "_")}_PREBUILT_ROOT=#{v.gsub(/ /, '\ ')}"]
    end

    environmental_variables = {}
    if deterministic_build
      environmental_variables["ZERO_AR_DATE"] = "1"
    end

    execute_command "xcodebuild", args, true, environmental_variables
  end

  # Copy paste implementation from CocoaPods internals to be able to call poopen3 passing environmental variables
  def self.execute_command(executable, command, raise_on_failure = true, environmental_variables = {})
    bin = Pod::Executable.which!(executable)

    command = command.map(&:to_s)
    full_command = "#{bin} #{command.join(" ")}"

    stdout = Pod::Executable::Indenter.new
    stderr = Pod::Executable::Indenter.new

    status = popen3(bin, command, stdout, stderr, environmental_variables)
    stdout = stdout.join
    stderr = stderr.join
    output = stdout + stderr
    unless status.success?
      if raise_on_failure
        raise "\n\n#{full_command}\n\n#{output}\n".red
      else
        UI.message("[!] Failed: #{full_command}".red)
      end
    end

    output
  end

  def self.popen3(bin, command, stdout, stderr, environmental_variables)
    require "open3"
    Open3.popen3(environmental_variables, bin, *command) do |i, o, e, t|
      Pod::Executable::reader(o, stdout)
      Pod::Executable::reader(e, stderr)
      i.close

      status = t.value

      o.flush
      e.flush
      sleep(0.01)

      status
    end
  end

  def self.enable_debug_information(project_path, configuration)
    project = Xcodeproj::Project.open(project_path)
    project.targets.each do |target|
      config = target.build_configurations.find { |config| config.name.eql? configuration }
      config.build_settings["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
      config.build_settings["ONLY_ACTIVE_ARCH"] = "NO"
    end
    project.save
  end
end

def self.copy_resources_and_vendored_items(installer_context, uses_frameworks, base_destination, sandbox)
  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      root_name = spec.name.split("/").first

      if uses_frameworks
        destination = File.join(base_destination, root_name)
      else
        destination = File.join(base_destination, root_name, root_name)
      end
      # Make sure the device target overwrites anything in the simulator build, otherwise iTunesConnect
      # can get upset about Info.plist containing references to the simulator SDK
      files = Pathname.glob("build/#{root_name}/*").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }

      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      files += file_accessor.vendored_libraries
      files += file_accessor.vendored_frameworks
      files += file_accessor.resources

      FileUtils.mkdir_p(destination)
      files.each do |file|
        FileUtils.cp_r(file, destination)
      end
    end
  end
end

Pod::HooksManager.register("podbuilder-rome", :post_install) do |installer_context, user_options|
  enable_dsym = user_options.fetch("dsym", true)
  configuration = user_options.fetch("configuration", "Debug")
  uses_frameworks = user_options.fetch("uses_frameworks", true)
  if user_options["pre_compile"]
    user_options["pre_compile"].call(installer_context)
  end
  build_catalyst = user_options.fetch("build_catalyst", false)
  build_xcframeworks = user_options.fetch("build_xcframeworks", false)

  prebuilt_root_paths = JSON.parse(user_options["prebuilt_root_paths"].gsub("=>", ":"))

  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  PodBuilder::enable_debug_information(sandbox.project_path, configuration)

  build_dir = sandbox_root.parent + "build"
  base_destination = sandbox_root.parent + "Prebuilt"

  build_dir.rmtree if build_dir.directory?
  base_destination.rmtree if base_destination.directory?

  targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
  raise "\n\nUnsupported target count\n".red unless targets.count == 1
  target = targets.first

  if build_xcframeworks
    project_path = sandbox_root.parent + "Pods/Pods.xcodeproj"

    case target.platform_name
    when :ios
      xcodebuild_settings = [PodBuilder::XcodeBuildSettings.new("iphoneos", configuration), PodBuilder::XcodeBuildSettings.new("iphonesimulator", configuration)]
      if build_catalyst
        xcodebuild_settings += [PodBuilder::XcodeBuildSettings.new("catalyst", configuration)]
      end
    when :osx then xcodebuild_settings = [PodBuilder::XcodeBuildSettings.new("macos", configuration)]
    when :tvos then xcodebuild_settings = [PodBuilder::XcodeBuildSettings.new("tvos", configuration), PodBuilder::XcodeBuildSettings.new("tvossimulator", configuration)]
    when :watchos then xcodebuild_settings = [PodBuilder::XcodeBuildSettings.new("watchos", configuration), PodBuilder::XcodeBuildSettings.new("watchossimulator", configuration)]
    else raise "\n\nUnknown platform '#{target.platform_name}'\n".red
    end

    xcodebuild_settings.each do |xcodebuild_setting|
      puts "Building xcframeworks for #{xcodebuild_setting.platform_name}".yellow

      log_path = "#{PodBuilder::Configuration.build_base_path}/archive_#{xcodebuild_setting.platform_name}.log"
      archive_cmd = "xcodebuild archive -project #{project_path.to_s} -scheme Pods-DummyTarget -configuration #{xcodebuild_setting.configuration} -destination '#{xcodebuild_setting.build_destination}' -archivePath '#{build_dir}/#{xcodebuild_setting.platform_name}' SKIP_INSTALL=NO > #{log_path}"
      unless system(archive_cmd)
        puts "\n\n#{xcodebuild_setting.build_destination} xcframework archive failed, see #{log_path}!\n".red
        if system("which xcbeautify")
          puts `cat '#{log_path}' | xcbeautify --is-ci`
        elsif system("which xcpretty")
          puts `cat '#{log_path}' | xcpretty`
        end
        raise ""
      end
    end

    built_items = Dir.glob("#{build_dir}/#{xcodebuild_settings[0].platform_name}.xcarchive/Products/Library/Frameworks/*").reject { |t| File.basename(t, ".*") == "Pods_DummyTarget" }

    specs = installer_context.umbrella_targets.map(&:specs).flatten
    built_items.each do |built_item|
      built_item_paths = [built_item]
      xcodebuild_settings.drop(1).each do |xcodebuild_setting|
        path = "#{build_dir}/#{xcodebuild_setting.platform_name}.xcarchive/Products/Library/Frameworks/#{File.basename(built_item)}"
        if File.directory?(path)
          built_item_paths.push(path)
        else
          built_item_paths = []
          break
        end
      end

      next if built_item_paths.count == 0

      module_name = File.basename(built_item_paths.first, ".*")
      spec = specs.detect { |t| t.module_name == module_name }

      # There seems to be a potential bug in CocoaPods-Core (https://github.com/CocoaPods/Core/issues/730)
      if spec.nil?
        # Given the above issue when all specs of a pod are subspecs (e.g. specs contains Pod1/Subspec1, Pod1/Subspec2, ...) we'll fail getting the correct specification by relying on module name
        spec = specs.detect { |t| t.name.split("/").first == module_name } || specs.detect { |t| t.parent&.module_name == module_name }
      end

      next if spec.nil?

      root_name = spec.name.split("/").first
      xcframework_path = "#{base_destination}/#{root_name}/#{module_name}.xcframework"
      framework_params = built_item_paths.map { |t| "-framework '#{t}'" }.join(" ")

      log_path = "#{PodBuilder::Configuration.build_base_path}/create_framework.log"
      create_framework_cmd = "xcodebuild -create-xcframework #{framework_params} -output '#{xcframework_path}' > #{log_path}"
      raise "\n\nFailed packing xcframework! See #{log_path}\n".red if !system(create_framework_cmd)

      if enable_dsym
        xcodebuild_settings.each do |xcodebuild_setting|
          dsym_source = "#{build_dir}/#{xcodebuild_setting.platform_name}.xcarchive/dSYMs/"
          if File.directory?(dsym_source)
            destination = PodBuilder::buildpath_dsympath
            FileUtils.mkdir_p(destination)
            FileUtils.mv(dsym_source, destination)
            FileUtils.mv("#{destination}/dSYMs", "#{destination}/#{xcodebuild_setting.platform_name}")
          end
        end
      else
        raise "\n\nNot implemented\n".red
      end
    end

    built_count = built_items.count
    Pod::UI.puts "Built #{built_count} #{"item".pluralize(built_count)}"

    copy_resources_and_vendored_items(installer_context, true, base_destination, sandbox)
  else
    case [target.platform_name, uses_frameworks]
    when [:ios, true] then PodBuilder::build_for_iosish_platform_framework(sandbox, build_dir, target, "iphoneos", "iphonesimulator", configuration, PodBuilder::Configuration.deterministic_build)
    when [:osx, true] then PodBuilder::xcodebuild(sandbox, target.cocoapods_target_label, configuration, PodBuilder::Configuration.deterministic_build, {})
    when [:tvos, true] then PodBuilder::build_for_iosish_platform_framework(sandbox, build_dir, target, "appletvos", "appletvsimulator", configuration, PodBuilder::Configuration.deterministic_build)
    when [:watchos, true] then PodBuilder::build_for_iosish_platform_framework(sandbox, build_dir, target, "watchos", "watchsimulator", configuration, PodBuilder::Configuration.deterministic_build)
    when [:ios, false] then PodBuilder::build_for_iosish_platform_lib(sandbox, build_dir, target, "iphoneos", "iphonesimulator", configuration, PodBuilder::Configuration.deterministic_build, prebuilt_root_paths)
    when [:osx, false] then PodBuilder::xcodebuild(sandbox, target.cocoapods_target_label, configuration, PodBuilder::Configuration.deterministic_build, prebuilt_root_paths)
    when [:tvos, false] then PodBuilder::build_for_iosish_platform_lib(sandbox, build_dir, target, "appletvos", "appletvsimulator", configuration, PodBuilder::Configuration.deterministic_build, prebuilt_root_paths)
    when [:watchos, false] then PodBuilder::build_for_iosish_platform_lib(sandbox, build_dir, target, "watchos", "watchsimulator", configuration, PodBuilder::Configuration.deterministic_build, prebuilt_root_paths)
    else raise "\n\nUnknown platform '#{target.platform_name}'\n".red
    end

    raise Pod::Informative, "The build directory was not found in the expected location." unless build_dir.directory?

    specs = installer_context.umbrella_targets.map { |t| t.specs.map(&:name) }.flatten.map { |t| t.split("/").first }.uniq
    built_count = Dir["#{build_dir}/*"].select { |t| specs.include?(File.basename(t)) }.count
    Pod::UI.puts "Built #{built_count} #{"item".pluralize(built_count)}, copying..."

    copy_resources_and_vendored_items(installer_context, uses_frameworks, base_destination, sandbox)

    # Depending on the resource it may happen that it is present twice, both in the .framework and in the parent folder
    Dir.glob("#{base_destination}/*") do |path|
      unless File.directory?(path)
        return
      end

      files = Dir.glob("#{path}/*")
      framework_files = Dir.glob("#{path}/*.framework/**/*").map { |t| File.basename(t) }

      files.each do |file|
        filename = File.basename(file.gsub(/\.xib$/, ".nib"))
        if framework_files.include?(filename)
          FileUtils.rm_rf(file)
        end
      end
    end

    if enable_dsym
      dsym_source = "#{build_dir}/dSYM"
      if File.directory?(dsym_source)
        FileUtils.mv(dsym_source, PodBuilder::buildpath_dsympath)
      end
    else
      raise "\n\nNot implemented\n".red
    end
  end

  build_dir.rmtree if build_dir.directory?

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end
end
