require "mkmf"
require "fileutils"

LERC_VERSION = "4.0.0"
LERC_REPO = "Esri/lerc"
LERC_LIB_NAME = "libLerc.so.4"

def download_file(url, destination)
  return if File.exist?(destination)
  
  puts "Downloading #{File.basename(destination)}..."
  system("curl -L -o #{destination} #{url}") or raise "Failed to download #{url}"
  puts "Downloaded to #{destination}"
end

def build_lerc_from_source
  puts "Building LERC from source..."
  build_dir = File.join(__dir__, 'lerc_build')
  FileUtils.mkdir_p(build_dir)
  
  begin
    archive_path = File.join(build_dir, "lerc-#{LERC_VERSION}.tar.gz")
    download_file("https://github.com/#{LERC_REPO}/archive/refs/tags/v#{LERC_VERSION}.tar.gz", archive_path)
    
    system("tar -xzf #{archive_path} -C #{build_dir}") or raise "Failed to extract archive"
    
    Dir.chdir("#{build_dir}/lerc-#{LERC_VERSION}") do
      FileUtils.mkdir_p('build')
      Dir.chdir('build') do
        system("cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON") or raise "CMake failed"
        system("make -j$(nproc)") or raise "Make failed"
        system("cp libLerc.so #{File.join(__dir__, LERC_LIB_NAME)}") or raise "Copy failed"
        puts "LERC library built successfully"
      end
    end
  ensure
    FileUtils.rm_rf(build_dir) if Dir.exist?(build_dir)
  end
end

download_file("https://raw.githubusercontent.com/nothings/stb/master/stb_image_write.h", 
              File.join(__dir__, 'stb_image_write.h'))

lerc_lib_path = File.join(__dir__, LERC_LIB_NAME)

unless File.exist?(lerc_lib_path)
  puts "LERC library not found. Building from source..."
  %w[cmake make].each { |tool| system("which #{tool} > /dev/null 2>&1") or abort "#{tool.capitalize} required" }
  build_lerc_from_source
  File.exist?(lerc_lib_path) or abort "Failed to build LERC library"
end

puts "Using LERC library: #{lerc_lib_path}"

$LDFLAGS += " -L#{__dir__}"
$LIBS += " -l:libLerc.so.4"
$CFLAGS += " -Wno-unused-function"

have_header('lerc_api.h') || have_header('lerc.h')

create_makefile("lerc_extension")

puts "Building C extension..."
system("make") or abort "Failed to build C extension"
puts "C extension built successfully"