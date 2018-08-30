require 'cocoapods'
require 'fileutils'
require 'colored'

require 'pod_builder/podfile'
require 'pod_builder/podfile_item'
require 'pod_builder/analyze'
require 'pod_builder/install'
require 'pod_builder/configuration'
require 'pod_builder/podspec'

require 'core_ext/string'

module PodBuilder  
  def self.safe_rm_rf(path)
    unless File.exist?(path)
      return
    end

    current_dir = Dir.pwd

    Dir.chdir(path)

    h = `git rev-parse --show-toplevel`.strip()
    raise "\n\nNo git repository found, can't delete files!\n".red if h.empty?

    FileUtils.rm_rf(path)

    if File.exist?(current_dir)
      Dir.chdir(current_dir)
    else
      Dir.chdir(basepath)
    end
  end

  def self.home
    h = `git rev-parse --show-toplevel`.strip()
    raise "\n\nNo git repository found in current folder `#{Dir.pwd}`!\n".red if h.empty?
    return h
  end
  
  def self.basepath(child = "")
    return "#{Configuration.base_path}/#{child}".gsub("//", "/").gsub(/\/$/, '')
  end
  
  def self.xcodepath(child = "")
    project = PodBuilder::find_xcodeproject
    
    return project ? "#{File.dirname(project)}/#{child}".gsub("//", "/").gsub(/\/$/, '') : nil
  end

  def self.find_xcodeproject
    return Dir.glob("#{home}/**/*.xcodeproj").detect { |x| !x.include?("/Pods/") && !x.include?(basepath) }
  end

  def self.find_xcodeworkspace
    return Dir.glob("#{home}/**/*.xcworkspace").detect { |x| !x.include?("/Pods/") && !x.include?(basepath) }
  end

  def self.prepare_basepath
    project = PodBuilder::find_xcodeproject
    if project
      FileUtils.mkdir_p(basepath("Pods/Target Support Files"))
      FileUtils.cp_r(project, basepath)   
      FileUtils.rm_f(basepath("Podfile.lock"))
    end
  end

  def self.clean_basepath
    project = PodBuilder::find_xcodeproject
    if project
      PodBuilder::safe_rm_rf(basepath(File.basename(project)))
      PodBuilder::safe_rm_rf(basepath("Pods"))
    end
  end
end