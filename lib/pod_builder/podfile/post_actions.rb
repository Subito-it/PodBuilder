require 'colored'
require 'xcodeproj'
require 'pod_builder/core'

module PodBuilder
  class Podfile
    def self.remove_target_support_duplicate_entries
      puts "[PodBuilder] Removing target support duplicated entries".yellow
      # Frameworks and resources
      find_xcodeproj_targets.map(&:name).each do |target|
        remove_duplicate_entries("Pods/Target Support Files/Pods-#{target}/Pods-#{target}-frameworks.sh")
        remove_duplicate_entries("Pods/Target Support Files/Pods-#{target}/Pods-#{target}-resources.sh")
      end
    end

    def self.check_target_support_resource_collisions
      puts "[PodBuilder] Checking target support resource collisions".yellow

      targets = find_xcodeproj_targets

      targets.map(&:name).each do |target|
        check_for_colliding_resources("Pods/Target Support Files/Pods-#{target}/Pods-#{target}-resources.sh", target, targets)
      end
    end

    private

    def self.remove_duplicate_entries(path)
      if !File.file?(path)
        return
      end
      
      # Adding the same pod to multiple targets results in duplicate entries in Pods-TARGET-frameworks.sh and Pods-TARGET-resources.sh (Cocoapods 1.4.0)
      # To avoid conflicts during parallel codesign we manually remove duplicates
      in_section_to_update = false
      processed_entries = []
      lines = []
      File.read(path).each_line do |line|
        stripped_line = line.strip()
        next if stripped_line.empty?

        if stripped_line.include?("if [[ \"$CONFIGURATION\" == ")
          in_section_to_update = true
        elsif stripped_line == "fi"
          in_section_to_update = false
          processed_entries = []
        end
        if in_section_to_update
          if processed_entries.include?(stripped_line)
            if !line.include?("#")
              line = "# #{line}"
            end
          end
          processed_entries.push(stripped_line)
        end
        
        lines.push(line)
      end
      
      File.write(path, lines.join)
    end

    def self.check_for_colliding_resources(path, target_name, targets)
      if !File.file?(path)
        return
      end

      if target = targets.detect { |x| x.name == target_name }
        resource_files = target.resources_build_phase.files.map { |i| i.file_ref.real_path.to_s }.to_set
        resource_files = resource_files.map { |i| File.basename(i) }
        resource_files = resource_files.map { |i| i.gsub(".xib", ".nib") }
      else
        raise "#{target} not found!".red
      end
      
      # Check that Pods-TARGET-resources.sh doesn't contain colliding entries (Cocoapods 1.4.0)
      in_section_to_update = false
      processed_entries = []
      File.read(path).each_line do |line|
        stripped_line = line.strip()
        next if stripped_line.empty?
        
        if stripped_line.include?("if [[ \"$CONFIGURATION\" == ")
          in_section_to_update = true
          next
        elsif stripped_line == "fi"
          in_section_to_update = false
          
          processed_entries.each do |entry|
            matches_other_framework = processed_entries.select { |t| t[0] == entry[0] }
            
            # Check for static framework cross-collisions
            if matches_other_framework.count > 1
              error = "\n\nCross-framework resource collision detected:\n"
              error += "#{entry[0]} found in\n"
              error += matches_other_framework.map { |x| "- #{x[1]}" }.join("\n")
              error += "\n\n"
              
              raise error.red
            end
            
            # Check for collisions with app's resources
            matches_app_resources = resource_files.select { |t| t == entry[0] }
            if matches_app_resources.count > 0
              error = "\n\nResource collision with app file detected:\n"
              error += "#{entry[0]} found in app but also in\n"
              error += matches_app_resources.map { |x| "- #{x[1]}" }.join("\n")
              error += "\n\n"
              
              raise error.red
            end
          end
          
          processed_entries = []
        end
        
        next if stripped_line.start_with?("#") # skip commented lines
        next if stripped_line.count("/..") > 2 # skip development pods
        
        line.gsub!("\"", "")
        line.gsub!("install_resource", "")
        line.strip!()
        
        if in_section_to_update
          filename = File.basename(line)
          processed_entries.push([filename, line])
        end
      end
    end

    def self.find_xcodeproj_targets
      xcodeprojects = Dir.glob("#{PodBuilder::home}/**/*.xcodeproj").select { |x| !x.include?("/Pods/") && !x.include?(PodBuilder::basepath) }
      raise "xcdeoproj not found!".red if xcodeprojects.count == 0
      raise "Found multiple xcdeoprojs:\n#{xcodeprojects.join("\n")}".red if xcodeprojects.count > 1
      
      project = Xcodeproj::Project.open(xcodeprojects.first)

      return project.targets
    end
  end
end
