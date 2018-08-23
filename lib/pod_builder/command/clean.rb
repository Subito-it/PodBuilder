require 'pod_builder/core'

module PodBuilder
  module Command
    class Clean
      def self.call(options)
        Configuration.check_inited
        PodBuilder::prepare_basepath

        update_repo = options[:update_repos] || false
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath)
        all_buildable_items = Analyze.podfile_items(installer, analyzer)

        podspec_names = all_buildable_items.map(&:podspec_name)
        rel_paths = all_buildable_items.map(&:prebuilt_rel_path)

        base_path = PodBuilder::basepath("Rome")
        framework_files = Dir.glob("#{base_path}/**/*.framework")
        clean(framework_files, base_path, rel_paths)

        rel_paths.map! { |x| "#{x}.dSYM"}

        base_path = PodBuilder::basepath("dSYM/iphoneos")
        dSYM_files_iphone = Dir.glob("#{base_path}/**/*.dSYM")
        clean(dSYM_files_iphone, base_path, rel_paths)

        base_path = PodBuilder::basepath("dSYM/iphonesimulator")
        dSYM_files_sim = Dir.glob("#{base_path}/**/*.dSYM")
        clean(dSYM_files_sim, base_path, rel_paths)

        clean_sources(podspec_names)

        puts "\n\n🎉 done!\n".green
        return true
      end

      def self.clean_sources(podspec_names)
        puts "Cleaning sources".blue
        
        base_path = PodBuilder::basepath("Sources")

        repo_paths = Dir.glob("#{base_path}/*")

        repo_paths.each do |path|
          podspec_name = File.basename(path)

          unless !podspec_names.include?(podspec_name)
            next
          end

          puts "Deleting sources #{path}".blue
          FileUtils.rm_rf(path)
        end
      end

      private

      def self.clean(files, base_path, rel_paths)
        files = files.map { |x| [Pathname.new(x).relative_path_from(Pathname.new(base_path)).to_s, x] }.to_h

        files.each do |rel_path, path|
          unless !rel_paths.include?(rel_path)
            next
          end

          puts "Deleting #{path}".blue
          FileUtils.rm_rf(path)
        end

        current_dir = Dir.pwd
        Dir.chdir(base_path)
        # Before deleting anything be sure we're in a git repo
        h = `git rev-parse --show-toplevel`.strip()
        raise "\n\nNo git repository found in current folder `#{Dir.pwd}`!\n".red if h.empty?    
        system("find . -type d -empty -delete") # delete empty folders
        Dir.chdir(current_dir)
      end
    end
  end
end
