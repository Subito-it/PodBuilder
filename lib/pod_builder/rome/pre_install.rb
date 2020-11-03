Pod::HooksManager.register('podbuilder-rome', :pre_install) do |installer_context|
  podfile = installer_context.podfile

  podfile.install!('cocoapods',
    podfile.installation_method.last.merge(:integrate_targets => false))
end
