require "digest"
require "colored"
require "highline/import"
require "pod_builder/core"

module PodBuilder
  class InstallResult
    # @return [Array<Hash>] The installed licenses
    #
    attr_reader :licenses

    # @return [Hash] A hash containing the expected prebuilt_info filename and content
    #
    attr_reader :prebuilt_info

    def initialize(licenses = [], prebuilt_info = Hash.new)
      @licenses = licenses
      @prebuilt_info = prebuilt_info
    end

    def +(obj)
      merged_licenses = @licenses.dup + obj.licenses
      merged_prebuilt_info = @prebuilt_info.dup

      merged_prebuilt_info.each do |key, value|
        if obj.prebuilt_info.has_key?(key)
          specs = merged_prebuilt_info[key]["specs"] || []
          specs += (obj.prebuilt_info[key]["specs"] || [])
          merged_prebuilt_info[key]["specs"] = specs.uniq
        end
      end

      merged_prebuilt_info = obj.prebuilt_info.merge(merged_prebuilt_info)

      return InstallResult.new(merged_licenses, merged_prebuilt_info)
    end

    def write_prebuilt_info_files
      prebuilt_info.each do |file_path, file_content|
        File.write(file_path, JSON.pretty_generate(file_content))
      end
    end
  end

  class Install
    # This method will generate prebuilt data by building from "/tmp/pod_builder/Podfile"
    def self.podfile(podfile_content, podfile_items, argument_pods, build_configuration)
      puts "Preparing build Podfile".yellow

      podfile_content = copy_development_pods_source_code(podfile_content, podfile_items)

      podfile_content = Podfile.update_path_entries(podfile_content, Install.method(:podfile_path_transform))
      podfile_content = Podfile.update_project_entries(podfile_content, Install.method(:podfile_path_transform))
      podfile_content = Podfile.update_require_entries(podfile_content, Install.method(:podfile_path_transform))

      if Configuration.react_native_project
        podfile_content = Podfile.prepare_react_native_compilation_workarounds(podfile_content)
      end

      podfile_path = File.join(Configuration.build_path, "Podfile")
      File.write(podfile_path, podfile_content)

      begin
        lock_file = "#{Configuration.build_path}/pod_builder.lock"
        FileUtils.touch(lock_file)

        prebuilt_entries = use_prebuilt_entries_for_unchanged_pods(podfile_path, podfile_items, argument_pods)

        install

        copy_prebuilt_items(podfile_items - prebuilt_entries)

        prebuilt_info = prebuilt_info(podfile_items, argument_pods)
        licenses = license_specifiers()

        if !OPTIONS.has_key?(:debug)
          PodBuilder::safe_rm_rf(Configuration.build_path)
        end

        return InstallResult.new(licenses, prebuilt_info)
      rescue Exception => e
        if File.directory?("#{Configuration.build_path}/Pods/Pods.xcodeproj")
          activate_pod_scheme()

          if ENV["DEBUGGING"]
            system("xed #{Configuration.build_path}/Pods")
          elsif !OPTIONS.has_key?(:no_stdin_available)
            confirm = ask("\n\nOh no! Something went wrong during prebuild phase! Do you want to open the prebuild project to debug the error, you will need to add and run the Pods-Dummy scheme? [Y/N] ".red) { |yn| yn.limit = 1, yn.validate = /[yn]/i }

            if confirm.downcase == "y"
              system("xed #{Configuration.build_path}/Pods")
            end
          end
        end

        raise e
      ensure
        FileUtils.rm(lock_file) if File.exist?(lock_file)
      end
    end

    def self.prebuilt_info(podfile_items, argument_pods)
      gitignored_files = PodBuilder::gitignoredfiles

      swift_version = PodBuilder::system_swift_version

      ret = Hash.new
      root_names = podfile_items.reject(&:is_prebuilt).map(&:root_name).uniq
      root_names.each do |prebuilt_name|
        path = PodBuilder::prebuiltpath(prebuilt_name)

        unless File.directory?(path)
          puts "Prebuilt items for #{prebuilt_name} not found".blue
          next
        end

        unless podfile_item = podfile_items.detect { |t| t.name == prebuilt_name } || podfile_items.detect { |t| t.root_name == prebuilt_name }
          puts "Prebuilt items for #{prebuilt_name} not found #2".blue
          next
        end

        podbuilder_file = File.join(path, Configuration.prebuilt_info_filename)
        entry = podfile_item.entry(true, false)

        data = {}
        data["entry"] = entry
        data["is_prebuilt"] = podfile_item.is_prebuilt
        if Dir.glob(File.join(path, "#{podfile_item.prebuilt_rel_path}/Headers/*-Swift.h")).count > 0
          data["swift_version"] = swift_version
        end

        specs = podfile_items.select { |x| x.root_name == podfile_item.root_name }
        subspecs_deps = specs.map(&:dependency_names).flatten
        subspec_self_deps = subspecs_deps.select { |x| x.start_with?("#{prebuilt_name}/") }
        data["specs"] = (specs.map(&:name) + subspec_self_deps).uniq
        data["is_static"] = podfile_item.is_static
        data["original_compile_path"] = Pathname.new(Configuration.build_path).realpath.to_s
        if hash = build_folder_hash(podfile_item, gitignored_files)
          data["build_folder_hash"] = hash
        end
        if argument_pods.include?(podfile_item.root_name)
          data["pb_version"] = PodBuilder::VERSION
        end

        ret.merge!({ podbuilder_file => data })
      end

      return ret
    end

    private

    def self.license_specifiers
      acknowledge_file = "#{Configuration.build_path}/Pods/Target Support Files/Pods-DummyTarget/Pods-DummyTarget-acknowledgements.plist"
      unless File.exist?(acknowledge_file)
        raise "\n\nLicense file not found\n".red
      end

      plist = CFPropertyList::List.new(:file => acknowledge_file)
      data = CFPropertyList.native_types(plist.value)

      return data["PreferenceSpecifiers"] || []
    end

    def self.copy_development_pods_source_code(podfile_content, podfile_items)
      # Development pods are normally built/integrated without moving files from their original paths.
      # It is important that CocoaPods compiles the files under Configuration.build_path in order that
      # DWARF debug info reference to this constant path. Doing otherwise breaks the assumptions that
      # makes  the `generate_lldbinit` command work.
      development_pods = podfile_items.select { |x| x.is_development_pod }
      development_pods.each do |podfile_item|
        destination_path = "#{Configuration.build_path}/Pods/#{podfile_item.name}"
        FileUtils.mkdir_p(destination_path)

        if Pathname.new(podfile_item.path).absolute?
          FileUtils.cp_r("#{podfile_item.path}/.", destination_path)
        else
          FileUtils.cp_r("#{PodBuilder::basepath(podfile_item.path)}/.", destination_path)
        end

        unless Configuration.build_using_repo_paths
          podfile_content.gsub!("'#{podfile_item.path}'", "'#{destination_path}'")
        end
      end

      return podfile_content
    end

    def self.use_prebuilt_entries_for_unchanged_pods(podfile_path, podfile_items, argument_pods)
      podfile_content = File.read(podfile_path)

      replaced_items = []

      download # Copy files under #{Configuration.build_path}/Pods so that we can determine build folder hashes

      gitignored_files = PodBuilder::gitignoredfiles

      prebuilt_root_paths = Hash.new

      puts "Optimizing build".yellow
      puts "Build strategy".blue

      prebuild_log = lambda { |item, reason|
        if item.is_prebuilt
          puts "#{item.root_name} is prebuilt"
        else
          puts "#{item.root_name} from source #{reason}".blue
        end
      }

      # Replace prebuilt entries in Podfile for Pods that have no changes in source code which will avoid rebuilding them
      items = podfile_items.group_by { |t| t.root_name }.map { |k, v| v.first }.sort_by { |t| t.root_name } # Return one podfile_item per root_name
      if OPTIONS.has_key?(:force_rebuild)
        rebuild_pods = items.select { |t| argument_pods.include?(t.root_name) }

        rebuild_pods.each do |item|
          prebuild_log.call(item, "")
        end

        items -= rebuild_pods
      end

      items.each do |item|
        podspec_path = item.prebuilt_podspec_path
        unless last_build_folder_hash = build_folder_hash_in_prebuilt_info_file(item)
          prebuild_log.call(item, "(folder hash missing)")
          next
        end

        if last_build_folder_hash == build_folder_hash(item, gitignored_files)
          puts "#{item.root_name} reuse PodBuilder cache"

          replaced_items.push(item)

          podfile_items.select { |t| t.root_name == item.root_name }.each do |replace_item|
            replace_regex = "pod '#{Regexp.quote(replace_item.name)}', .*"
            replace_line_found = podfile_content =~ /#{replace_regex}/i
            raise "\n\nFailed finding pod entry for '#{replace_item.name}'\n".red unless replace_line_found
            podfile_content.gsub!(/#{replace_regex}/, replace_item.prebuilt_entry(true, true))

            prebuilt_root_paths[replace_item.root_name] = PodBuilder::prebuiltpath
          end
        else
          prebuild_log.call(item, "(folder hash mismatch)")
        end
      end

      podfile_content.gsub!("%%%prebuilt_root_paths%%%", prebuilt_root_paths.to_s)

      File.write(podfile_path, podfile_content)

      return replaced_items
    end

    def self.install
      puts "Preparing build".yellow

      CLAide::Command::PluginManager.load_plugins("cocoapods")

      Dir.chdir(Configuration.build_path) do
        config = Pod::Config.new()
        installer = Pod::Installer.new(config.sandbox, config.podfile, config.lockfile)
        installer.repo_update = false
        installer.update = false

        install_start_time = Time.now

        installer.install!
        install_time = Time.now - install_start_time

        puts "Build completed in #{install_time.to_i} seconds".blue
      end
    end

    def self.download
      puts "Downloading Pods source code".yellow

      CLAide::Command::PluginManager.load_plugins("cocoapods")

      Dir.chdir(Configuration.build_path) do
        Pod::UserInterface::config.silent = true

        config = Pod::Config.new()
        installer = Pod::Installer.new(config.sandbox, config.podfile, config.lockfile)
        installer.repo_update = false
        installer.update = false
        installer.prepare
        installer.resolve_dependencies
        installer.download_dependencies

        Pod::UserInterface::config.silent = false
      end
    end

    def self.copy_prebuilt_items(podfile_items)
      FileUtils.mkdir_p(PodBuilder::prebuiltpath)

      non_prebuilt_items = podfile_items.reject(&:is_prebuilt)

      non_prebuilt_items.reject! { |item|
        [item.module_name, item.root_name]
          .map { |t| PodBuilder::buildpath_prebuiltpath(t) }
          .select { |t| File.directory?(t) }
          .all? { |t| Dir.empty?(t) } # When using prebuilt items we end up with empty folders
      }

      non_prebuilt_items.each do |item|
        # Remove existing files
        items_to_delete = Dir.glob("#{PodBuilder::prebuiltpath(item.root_name)}/**/*")
        items_to_delete.each { |t| PodBuilder::safe_rm_rf(t) }
      end

      # Now copy
      non_prebuilt_items.each do |item|
        source_path = PodBuilder::buildpath_prebuiltpath(item.root_name)

        unless File.directory?(source_path)
          puts "Prebuilt items for #{item.root_name} not found".blue
          next
        end

        unless Dir.glob("#{source_path}/**/*").select { |t| File.file?(t) }.empty?
          destination_folder = PodBuilder::prebuiltpath(item.root_name)
          FileUtils.mkdir_p(destination_folder)
          FileUtils.cp_r("#{source_path}/.", destination_folder)
        end
      end

      # Folder won't exist if no dSYM were generated (all static libs)
      if File.directory?(PodBuilder::buildpath_dsympath)
        FileUtils.mkdir_p(PodBuilder::dsympath)
        FileUtils.cp_r(PodBuilder::buildpath_dsympath, PodBuilder::basepath)
      end
    end

    def self.build_folder_hash_in_prebuilt_info_file(podfile_item)
      prebuilt_info_path = PodBuilder::prebuiltpath(File.join(podfile_item.root_name, Configuration.prebuilt_info_filename))

      if File.exist?(prebuilt_info_path)
        data = JSON.parse(File.read(prebuilt_info_path))
        return data["build_folder_hash"]
      else
        return nil
      end
    end

    def self.build_folder_hash(podfile_item, exclude_files)
      if podfile_item.is_development_pod
        if Pathname.new(podfile_item.path).absolute?
          item_path = podfile_item.path
        else
          item_path = PodBuilder::basepath(podfile_item.path)
        end

        rootpath = PodBuilder::git_rootpath
        file_hashes = []
        Dir.glob("#{item_path}/**/*", File::FNM_DOTMATCH) do |path|
          unless File.file?(path)
            next
          end

          path = File.expand_path(path)
          rel_path = path.gsub(rootpath, "")[1..]

          unless exclude_files.any? { |t| rel_path.start_with?(t) }
            file_hashes.push(Digest::MD5.hexdigest(File.read(path)))
          end
        end

        return Digest::MD5.hexdigest(file_hashes.sort.join)
      else
        # Pod folder might be under .gitignore
        item_path = "#{Configuration.build_path}/Pods/#{podfile_item.root_name}"
        if File.directory?(item_path)
          return `find '#{item_path}' -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1`.strip()
        else
          return nil
        end
      end
    end

    def self.podfile_path_transform(path)
      if Configuration.build_using_repo_paths
        return File.expand_path(PodBuilder::basepath(path))
      else
        use_absolute_paths = true
        podfile_path = File.join(Configuration.build_path, "Podfile")
        original_basepath = PodBuilder::basepath

        podfile_base_path = Pathname.new(File.dirname(podfile_path))

        original_path = Pathname.new(File.join(original_basepath, path))
        replace_path = original_path.relative_path_from(podfile_base_path)
        if use_absolute_paths
          replace_path = replace_path.expand_path(podfile_base_path)
        end

        return replace_path
      end
    end

    def self.activate_pod_scheme
      if scheme_file = Dir.glob("#{Configuration.build_path}/Pods/**/xcschememanagement.plist").first
        plist = CFPropertyList::List.new(:file => scheme_file)
        data = CFPropertyList.native_types(plist.value)

        if !data.dig("SchemeUserState", "Pods-DummyTarget.xcscheme").nil?
          data["SchemeUserState"]["Pods-DummyTarget.xcscheme"]["isShown"] = true
        end

        plist.value = CFPropertyList.guess(data)
        plist.save(scheme_file, CFPropertyList::List::FORMAT_BINARY)
      end
    end
  end
end

# CocoaPods seems to hard code the development language to english
# By monkey patching the project save we make sure that the to manually rewrite the
# development language if it has been manually specified in PodBuilder's configuration
class Xcodeproj::Project
  alias_method :swz_save, :save

  def save(save_path = nil)
    if development_language = PodBuilder::Configuration.development_language
      root_object.development_region = development_language
    end

    swz_save(save_path)
  end
end
