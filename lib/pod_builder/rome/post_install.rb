require 'fourflusher'

module PodBuilder
  def self.build_for_iosish_platform(sandbox, build_dir, target, device, simulator, configuration, deterministic_build)
    deployment_target = target.platform_deployment_target
    target_label = target.cocoapods_target_label

    PodBuilder::xcodebuild(sandbox, target_label, device, deployment_target, configuration, deterministic_build)
    PodBuilder::xcodebuild(sandbox, target_label, simulator, deployment_target, configuration, deterministic_build)

    spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
    spec_names.each do |root_name, module_name|
      executable_path = "#{build_dir}/#{root_name}"
      device_lib = "#{build_dir}/#{configuration}-#{device}/#{root_name}/#{module_name}.framework/#{module_name}"
      device_framework_lib = File.dirname(device_lib)
      device_swift_header_path = "#{device_framework_lib}/Headers/#{module_name}-Swift.h"

      simulator_lib = "#{build_dir}/#{configuration}-#{simulator}/#{root_name}/#{module_name}.framework/#{module_name}"
      simulator_framework_lib = File.dirname(simulator_lib)
      simulator_swift_header_path = "#{simulator_framework_lib}/Headers/#{module_name}-Swift.h"

      next unless File.file?(device_lib) && File.file?(simulator_lib)
      
      # Starting with Xcode 12b3 the simulator binary contains an arm64 slice as well which conflict with the one in the device_lib when creating the fat library
      if `lipo -info #{simulator_lib}`.include?("arm64")
        `lipo -remove arm64 #{simulator_lib} -o #{simulator_lib}`
      end

      lipo_log = `lipo -create -output #{executable_path} #{device_lib} #{simulator_lib}`
      puts lipo_log unless File.exist?(executable_path)

      # Merge swift headers as per Xcode 10.2 release notes
      if File.exist?(device_swift_header_path) && File.exist?(simulator_swift_header_path)
        device_content = File.read(device_swift_header_path)
        simulator_content = File.read(simulator_swift_header_path)
        merged_content = %{
#if TARGET_OS_SIMULATOR
#{simulator_content}
#else
#{device_content}
#endif
}        
        File.write(device_swift_header_path, merged_content)
      end

      FileUtils.mv executable_path, device_lib, :force => true
      FileUtils.mv device_framework_lib, build_dir, :force => true
      FileUtils.rm simulator_lib if File.file?(simulator_lib)
      FileUtils.rm device_lib if File.file?(device_lib)
    end
  end

  def self.xcodebuild(sandbox, target, sdk='macosx', deployment_target=nil, configuration, deterministic_build)
    args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target} -configuration #{configuration} -sdk #{sdk})
    platform = PLATFORMS[sdk]
    args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?

    env = {}

    execute_command 'xcodebuild', args, true, env
  end

  # Copy paste implementation from CocoaPods internals to be able to call poopen3 passing environmental variables
  def self.execute_command(executable, command, raise_on_failure = true, env = {})
    bin = Pod::Executable.which!(executable)

    command = command.map(&:to_s)
    full_command = "#{bin} #{command.join(' ')}"

    stdout = Pod::Executable::Indenter.new
    stderr = Pod::Executable::Indenter.new

    status = popen3(bin, command, stdout, stderr, env)
    stdout = stdout.join
    stderr = stderr.join
    output = stdout + stderr
    unless status.success?
      if raise_on_failure
        raise Informative, "#{full_command}\n\n#{output}"
      else
        UI.message("[!] Failed: #{full_command}".red)
      end
    end

    output
  end

  def self.popen3(bin, command, stdout, stderr, env)
    require 'open3'
    Open3.popen3(env, bin, *command) do |i, o, e, t|
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
      config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
      config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
    end
    project.save
  end

  def self.copy_dsym_files(dsym_destination, configuration)
    dsym_destination.rmtree if dsym_destination.directory?
    platforms = ['iphoneos', 'iphonesimulator']
    platforms.each do |platform|
      dsym = Pathname.glob("build/#{configuration}-#{platform}/**/*.dSYM")
      dsym.each do |dsym|
        destination = dsym_destination + platform
        FileUtils.mkdir_p destination
        FileUtils.cp_r dsym, destination, :remove_destination => true
      end
    end
  end
end

Pod::HooksManager.register('podbuilder-rome', :post_install) do |installer_context, user_options|
  enable_dsym = user_options.fetch('dsym', true)
  configuration = user_options.fetch('configuration', 'Debug')
  if user_options["pre_compile"]
    user_options["pre_compile"].call(installer_context)
  end

  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  PodBuilder::enable_debug_information(sandbox.project_path, configuration) if enable_dsym

  build_dir = sandbox_root.parent + 'build'
  destination = sandbox_root.parent + 'Rome'

  Pod::UI.puts 'Building frameworks'

  build_dir.rmtree if build_dir.directory?
  targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
  targets.each do |target|
    case target.platform_name
    when :ios then PodBuilder::build_for_iosish_platform(sandbox, build_dir, target, 'iphoneos', 'iphonesimulator', configuration, PodBuilder::Configuration.deterministic_build)
    when :osx then PodBuilder::xcodebuild(sandbox, target.cocoapods_target_label, configuration, PodBuilder::Configuration.deterministic_build)
    when :tvos then PodBuilder::build_for_iosish_platform(sandbox, build_dir, target, 'appletvos', 'appletvsimulator', configuration, PodBuilder::Configuration.deterministic_build)
    when :watchos then PodBuilder::build_for_iosish_platform(sandbox, build_dir, target, 'watchos', 'watchsimulator', configuration, PodBuilder::Configuration.deterministic_build)
    else raise "Unknown platform '#{target.platform_name}'" end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

  # Make sure the device target overwrites anything in the simulator build, otherwise iTunesConnect
  # can get upset about Info.plist containing references to the simulator SDK
  frameworks = Pathname.glob("build/*/*/*.framework").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }
  frameworks += Pathname.glob("build/*.framework").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }

  resources = []

  Pod::UI.puts "Built #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)}"

  destination.rmtree if destination.directory?

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      frameworks += file_accessor.vendored_libraries
      frameworks += file_accessor.vendored_frameworks
      resources += file_accessor.resources
    end
  end
  frameworks.uniq!
  resources.uniq!

  Pod::UI.puts "Copying #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)} " \
    "to `#{destination.relative_path_from Pathname.pwd}`"

  FileUtils.mkdir_p destination
  (frameworks + resources).each do |file|
    FileUtils.cp_r file, destination, :remove_destination => true
  end

  PodBuilder::copy_dsym_files(sandbox_root.parent + 'dSYM', configuration) if enable_dsym

  build_dir.rmtree if build_dir.directory?

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end
end
