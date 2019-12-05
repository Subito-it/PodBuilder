 module PodBuilder
  class Licenses
    def self.write(licenses, all_buildable_items)
      puts "Writing licenses".yellow
      license_file_path = PodBuilder::project_path(Configuration.license_filename) + ".plist"

      current_licenses = []
      if File.exist?(license_file_path)
        plist = CFPropertyList::List.new(:file => license_file_path)
        dict = CFPropertyList.native_types(plist.value)  
        current_licenses = dict["PreferenceSpecifiers"]
      
        if current_licenses.count > 0 
          licenses_header = current_licenses.shift
          raise "Unexpected license found in header" if licenses_header.has_key?("License")
        end
        if current_licenses.count > 0 
          license_footer = current_licenses.pop
          raise "Unexpected license found in footer" if license_footer.has_key?("License")
        end
      end

      if licenses.count > 0
        licenses_header = licenses.shift
        raise "Unexpected license found in header" if licenses_header.has_key?("License")
        license_footer = licenses.pop
        raise "Unexpected license found in footer" if license_footer.has_key?("License")

        lincenses_titles = licenses.map { |x| x["Title"] }
        current_licenses.select! { |x| !lincenses_titles.include?(x["Title"]) }
      end

      licenses += current_licenses # merge with existing license
      licenses.uniq! { |x| x["Title"] }
      licenses.sort_by! { |x| x["Title"] }
      licenses.select! { |x| !Configuration.skip_licenses.include?(x["Title"]) }
      licenses.select! { |x| all_buildable_items.map(&:root_name).include?(x["Title"]) } # Remove items that are no longer included

      license_dict = {}
      license_dict["PreferenceSpecifiers"] = [licenses_header, licenses, license_footer].compact.flatten
      license_dict["StringsTable"] = "Acknowledgements"
      license_dict["Title"] = license_dict["StringsTable"]

      plist = CFPropertyList::List.new
      plist.value = CFPropertyList.guess(license_dict)
      plist.save(license_file_path, CFPropertyList::List::FORMAT_BINARY)

      if licenses.count > 0
        write_markdown(license_file_path)
      end
    end
    
    private 

    def self.write_markdown(plist_path)
      plist = CFPropertyList::List.new(:file => plist_path)
      dict = CFPropertyList.native_types(plist.value)  
      licenses = dict["PreferenceSpecifiers"]

      header = licenses.shift

      markdown = []
      markdown += ["# #{header["Title"]}", header["FooterText"], ""]
      markdown += licenses.map { |x| ["## #{x["Title"]}", x["FooterText"], ""] }

      markdown.flatten!

      markdown_path = plist_path.chomp(File.extname(plist_path)) + ".md"

      File.write(markdown_path, markdown.join("\n"))
    end
  end
end