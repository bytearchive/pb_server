require 'sequel'
require 'fileutils'
require 'digest/md5'

module PB
#
# Photo represents photos in our system
#
class Photo < Sequel::Model(:photos)
		
#	property :display_name,	String
#	property :storage,			String # where is the image stored locally
#	property :md5,					String # md5 hash

	plugin :timestamps
	
	many_to_one :user
	many_to_many :books
	
	DISPLAY_SIZE = 1024
	ICON_SIZE = 256

	def to_json(*a)
		{
			:id => self.id,
			:display_name => self.display_name,
			:md5 => self.md5
		}.to_json(*a)
	end

	def file_path(*size_arg) # call with no args for full size, or specify size as 'icon'|'display'
		size = size_arg.length > 0 ? size_arg[0] : "";
		size = size.to_s
		# transform filename.jpg to filename_size.jpg
		name_arry = self.storage.rpartition(File.extname(self.storage)) # [ "file", ".jpg", ""]
		name_arry.insert(1, "_icon") if size.eql? 'icon'
		name_arry.insert(1, "_display") if size.eql? 'display'
		File.join( PhotoStorage.get_user_dir(self), name_arry.join )
	end
	
	def url()
		"/photo/" + self.id.to_s
	end
	
	def before_destroy
		PB.logger.info("destroying photo #{self.pk}#{self.display_name}")
		PhotoStorage.destroyFile self
	end
end

# Photos are stored inside SvegSettings.photo_dir/:user_id/:photo_id.img
# 
class PhotoStorage
	# stores the uploaded file, and updates
	
	def self.get_user_dir(photo)
		dir = File.join(SvegSettings.photo_dir, photo.user_id.to_s)
		FileUtils.mkdir_p(dir)
		dir
	end
	
	def self.auto_orient(path)
		# ImageMagick takes 1.3s to start up, so we query with gm to see if rotation is necessary
		cmd_query = "#{SvegSettings.graphicsmagick_binary} identify \"#{path}\" -format \"%[EXIF:Orientation]\""
		result  = `#{cmd_query}`.chomp
		raise ("Could not query orientation " + $?.to_s) unless $? == 0
		return if (result.eql?("unknown") || result.eql?("1")) # photo property oriented
		PB.logger.info("auto-orienting image")
# would like to use GraphicsMagick after all, see http://stackoverflow.com/questions/4263758/does-graphicsmagick-have-an-equivalent-to-imagemagick-convert-auto-orient-opt
#		transformation = case 
#			when result.eql?("2") then "-flip horizontal"
#			when result.eql?("3") then "-rotate 180"
#			when result.eql?("4") then "-flip vertical"
#			when result.eql?("5") then "-transpose"
#			when result.eql?("6") then "-rotate 90"
#			when result.eql?("7") then "-transverse"
#			when result.eql?("8") then "-rotate 270"
#			else ""
#		end
#		cmd_line = "#{SvegSettings.graphicsmagick_binary} convert \"#{path}\""
# would need tool like exiv2 to set exif data, it'll probably shave off a second, and remove imagemagick dependency
		cmd_line = "#{SvegSettings.convert_binary} -auto-orient \"#{path}\"  \"#{path}\""
		success = Kernel.system cmd_line
		raise("Photo orient failed" + $?.to_s) unless success
	end

	def self.get_cmd_resize(size, src, dest)
		cmd_line = "#{SvegSettings.graphicsmagick_binary} convert"
		cmd_line += " -size #{size}X#{size} #{src} +profile \"*\""
		cmd_line += " -geometry #{size}X#{size} #{dest}"
		cmd_line
	end

	# conversts photo to various sizes
	# src: photo file path
	# sizes: { 128 => :icon, 1024 => :display }
	# returns: array of new files
	def self.multi_resize(src, sizes)
		src = File.expand_path(src)

		ext = File.extname(src)
		basename = File.basename(src, ext)
		dirname = File.dirname(src)
		ext = ext.downcase

		resized_files = {}
		keys = sizes.keys.sort.reverse
		cmd_line =  "#{SvegSettings.graphicsmagick_binary} convert"
		# read in file, remove exif data
		cmd_line += " -size #{keys.first}X#{keys.first} #{src} +profile \"*\""
		0.upto(keys.length - 1) do |i|
			dest_name = "#{dirname}/#{basename}_#{sizes[keys[i]].to_s}#{ext}"
			next if File.exists? dest_name
			cmd_line += "  -geometry \"#{(keys[i] * 1.33).to_i}X#{keys[i]}>\" -write #{dest_name}"
			resized_files[keys[i]] = dest_name
		end
		dest_name = "#{dirname}/#{basename}_#{sizes[keys.last].to_s}#{ext}"
		unless File.exists? dest_name 
			cmd_line += " -geometry \"#{(keys.last * 1.33).to_i}X#{keys.last}>\" #{dest_name}"
			resized_files[keys[0]] = dest_name
		end

		if cmd_line.match(/geometry/) # there is something to convert
			success = Kernel.system cmd_line 
			raise("Photo resize failed" + $?.to_s) unless success
		end

		return resized_files
	end

	def self.resize(photo)
		src = File.expand_path(photo.file_path)
		self.multi_resize(src, { Photo::ICON_SIZE => :icon, Photo::DISPLAY_SIZE => :display })
	end
	
	def self.storeFile(photo, file_path)
		photo.save
		dir = self.get_user_dir(photo)
		ext = File.extname( photo.display_name ).downcase
		ext = ".img" unless [".jpg", ".gif", ".png"].index(ext)
		destName = photo.id.to_s + ext
		dest = File.join(dir, destName)
		FileUtils.mv(file_path, dest)
		photo.md5 = Digest::MD5.hexdigest(File.read(dest))
		photo.storage = destName
		photo.save
		# file post-processing: orient, and generate sizes
		self.auto_orient(photo.file_path) 
		self.resize(photo)
	end
	
	def self.destroyFile(photo)
		begin
			File.delete(photo.file_path)
		rescue => ex
			PB.logger.error "Could not destroy file #{photo.file_path} " + ex.message
		end
		begin 
			File.delete(photo.file_path(:icon)) 
		rescue 
		end
		begin 
			File.delete(photo.file_path(:display)) 
		rescue 
		end
		photo.storage = ""
		photo.md5 = ""
		photo.save
		PB.logger.info("photo file deleted")
	end
	
end

end