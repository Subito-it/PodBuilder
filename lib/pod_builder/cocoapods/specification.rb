module Pod
  class Specification
    def recursive_dep_names(all_specs)
      base_deps = all_dependencies.map(&:name)

      loop do
        last_deps_count = base_deps.count
        
        all_specs.each do |s|
          unless s != self
            next
          end

          specs_deps = s.all_dependencies.map(&:name)
          if base_deps.include?(s.name)
            base_deps += specs_deps
            base_deps.uniq!
          end
        end
        
        break unless last_deps_count != base_deps.count
      end 

      return base_deps
    end    
  end
end
