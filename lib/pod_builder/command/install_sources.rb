require 'pod_builder/core'

module PodBuilder
  module Command
    class InstallSources
      def self.call(options)
        Configuration.check_inited
        PodBuilder::prepare_basepath

        update_repo = options[:update_repos] || false
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath)
        framework_items = Analyze.podfile_items(installer, analyzer).select { |x| !x.is_prebuilt }
        podspec_names = framework_items.map(&:podspec_name)

        base_path = PodBuilder::basepath("Rome")
        framework_files = Dir.glob("#{base_path}/**/*.framework")
        
        framework_files.each do |path|
          rel_path = Pathname.new(path).relative_path_from(Pathname.new(base_path)).to_s

          if framework_spec = framework_items.detect { |x| x.prebuilt_rel_path == rel_path }
            update_repo(framework_spec)
          end
        end

        Command::Clean::clean_sources()

        rewrite_lldinit

        puts "\n\n🎉 done!\n".green
        return true
      end

      private

      def self.update_repo(spec)
        dest_path = PodBuilder::basepath("Sources")
        FileUtils.mkdir_p(dest_path)

        current_dir = Dir.pwd
        Dir.chdir(dest_path)

        repo_dir = File.join(dest_path, spec.podspec_name)
        if !File.directory?(repo_dir)
          raise "Failed cloning #{spec.name}" if !system("git clone #{spec.repo} #{spec.podspec_name}")
        end

        Dir.chdir(repo_dir)
        puts "Checking out #{spec.podspec_name}".blue
        raise "Failed cheking out #{spec.name}" if !system(spec.git_hard_checkout)

        Dir.chdir(current_dir)
      end

      def self.rewrite_lldinit
        puts "Writing ~/.lldbinit-Xcode".blue

        lldbinit_path = File.expand_path('~/.lldbinit-Xcode')
        FileUtils.touch(lldbinit_path)

        lldbinit_lines = []
        File.read(lldbinit_path).each_line do |line|
          if lldbinit_lines.include?(line.strip()) ||
             line.start_with?("settings set target.source-map") ||
             line.strip() == "" then
            next
          end
            
          lldbinit_lines.push(line)
        end

        build_path = "#{PodBuilder::Configuration.build_path}/Pods"
        source_path = PodBuilder::basepath("Sources")

        lldbinit_lines.push("settings set target.source-map '#{build_path}' '#{source_path}'")
        lldbinit_lines.push("")
      
        File.write(lldbinit_path, lldbinit_lines.join("\n"))
      end
    end
  end
end
