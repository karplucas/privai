Pod::Spec.new do |spec|
  spec.name                  = 'ChatterboxNative'
  spec.version               = '0.1.0'
  spec.summary               = 'Native codec.cpp runtime for Chatterbox GGUF TTS.'
  spec.homepage              = 'https://github.com/mybigday/codec.cpp'
  spec.license               = { :type => 'MIT' }
  spec.author                = 'PrivAI'
  spec.platform              = :ios, '16.0'
  spec.source                = { :path => '.' }
  spec.vendored_frameworks   = 'Chatterbox.xcframework', 'ChatterboxBackbone.xcframework'
  spec.frameworks            = 'Accelerate', 'Foundation'
  spec.pod_target_xcconfig   = { 'DEFINES_MODULE' => 'YES' }
end
