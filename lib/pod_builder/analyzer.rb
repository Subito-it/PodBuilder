require 'cocoapods/installer/analyzer.rb'

module Pod
  class Installer
    class Analyzer
        def explicit_pods
            pods = []
            podfile.root_target_definitions[0].children.each do |children|
                pods += children.dependencies
            end

            pods.flatten.uniq.sort
        end
    end
  end
end