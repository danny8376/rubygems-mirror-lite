#!/usr/bin/env ruby
# ================== Rubygems Mirror LITE ==================
#  Before use this program, please make a "mirror-conf.rb"
#  (mirror-conf.rb.example is an example file)
# ----------------------------------------------------------
#  Dependency:
#    Gems:
#      EventMachine
#    Sys-Util:
#      Wget
# ----------------------------------------------------------
#  Usage: rubygems-pull.rb [check]
#  Run without parameter -> normal mirror sync
#    (Will consume large time when first run)
#    (Full mirror will take approximately 150GB)
#  Run with "check" -> ignore specs difference
#    force to check all gems
#    ( only download new & failed gems )
# ----------------------------------------------------------
#  Keep sync:
#    Just add this script to crontab, or
#    you may wish write a systemd timer if using systemd
#    (You may want to redirect output on crontab)
# ==========================================================
require "rubygems"
require "open-uri"
require "eventmachine"
require "fileutils"

require "./mirror-conf.rb"

# download function
def download(fn)
	EM.system("wget -q -N -O #{MIRROR_FOLDER}/mirror/#{fn} http://production.cf.rubygems.org/#{fn}") { |out, status|
		yield status.exitstatus == 0 if block_given?
	}
end

# metadata reader
def read_metafile
	specs = Marshal.load(Gem.gunzip(open("#{MIRROR_FOLDER}/mirror/specs.4.8.gz"){|f| f.read}))
	latest_specs = Marshal.load(Gem.gunzip(open("#{MIRROR_FOLDER}/mirror/latest_specs.4.8.gz", "rb") {|f| f.read}))
	prerelease_specs = Marshal.load(Gem.gunzip(open("#{MIRROR_FOLDER}/mirror/prerelease_specs.4.8.gz", "rb") {|f| f.read}))

	all_specs = specs + latest_specs + prerelease_specs
	all_specs.uniq!
	all_specs
rescue
	return []
end

# download wrapper for metadata downloading
def meta_dl(fn)
	if File.exist? "#{MIRROR_FOLDER}/mirror/#{fn}"
		FileUtils.cp("#{MIRROR_FOLDER}/mirror/#{fn}", "#{MIRROR_FOLDER}/meta_backup/#{fn}") # backup ori files
	end
	$metadata_dl_list[fn] = true # mark it as downloading
	download(fn) { |res|
		$meta_fail = true unless res
		$metadata_dl_list[fn] = false
	}
end

def meta_fail
	$metadata_dl_list.keys.each { |fn|
		if File.exist? "#{MIRROR_FOLDER}/meta_backup/#{fn}"
			FileUtils.cp("#{MIRROR_FOLDER}/meta_backup/#{fn}", "#{MIRROR_FOLDER}/mirror/#{fn}") # restore ori files
		end
	}
	EM.stop
end

# metadata download waiter ** must give a block **
def meta_dl_wait
	$meta_dl_wait_cb = Proc.new if block_given?
	if $metadata_dl_list.values.any? # still downloading
		EM.add_timer(1) { meta_dl_wait } # check again 1s later
	else
		if $meta_fail ### failed !!!!
			meta_fail
		else
			cb = $meta_dl_wait_cb
			$meta_dl_wait_cb = nil
			cb.call
		end
	end
end

# do metadata downloading OwO ** must give a block **
def download_metadata
	$metadata_dl_list = {}

	meta_dl "Marshal.4.8"
	meta_dl "Marshal.4.8.Z"

	meta_dl "yaml"
	meta_dl "yaml.Z"

	meta_dl "specs.4.8"
	meta_dl "specs.4.8.gz"

	meta_dl "latest_specs.4.8"
	meta_dl "latest_specs.4.8.gz"

	meta_dl "prerelease_specs.4.8"
	meta_dl "prerelease_specs.4.8.gz"

	meta_dl_wait {
		$metadata_dl_list = nil
		yield
	}
end

# gem downloader !!!
def pull(qno, force = false)
	$main_dl_queue[qno * 2] = true # mark as working ( *2 => 0:gemspec 1:gem )
	$main_dl_queue[qno * 2 + 1] = true

	gem = $specs_add.shift
	unless gem
		$main_dl_queue[qno * 2] = false
		$main_dl_queue[qno * 2 + 1] = false
		return
	end

	# check for accidently removed gems (?
	if force and not $specs.include?(gem)
		$failed_gems.delete gem if $failed_gems.include?(gem)
	end

	fn = "#{gem[0]}-#{gem[1].version}#{"-#{gem[2]}" if gem[2] != "ruby"}"

	if not force and
			File.exist? "#{MIRROR_FOLDER}/mirror/gems/#{fn}.gem" and
			File.size? "#{MIRROR_FOLDER}/mirror/gems/#{fn}.gem" and
			File.exist? "#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8/#{fn}.gemspec.rz" and
			File.size? "#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8/#{fn}.gemspec.rz"
		$main_dl_queue[qno * 2] = false
		$main_dl_queue[qno * 2 + 1] = false
		EM.next_tick { pull_finish_check qno, gem, fn, true, force, true } # skipped => process as normal download
		return
	end
	download("quick/Marshal.4.8/#{fn}.gemspec.rz") { |res|
		$main_dl_queue[qno * 2] = false
		print "#{fn}.gemspec.rz download failed!\n" unless res
		pull_finish_check qno, gem, fn, res, force
	}
	download("gems/#{fn}.gem") { |res|
		$main_dl_queue[qno * 2 + 1] = false
		print "#{fn}.gem download failed!\n" unless res
		pull_finish_check qno, gem, fn, res, force
	}
end

def pull_finish_check(qno, gem, fn, res, force, skip = false)
	$failed_gems.push gem if not res and not $failed_gems.include?(gem)
	if $main_dl_queue[qno * 2] or $main_dl_queue[qno * 2 + 1] # gem download process still unfinished
		return
	else
		print "#{fn} #{skip ? "skipped" : "downloaded"}! #{$specs_add.size}\n"
		$failed_gems.delete gem if force and $failed_gems.include?(gem) # remove failed gems when succeed
		if $specs_add.empty? and not $main_dl_queue.any?
			finish
		else
			pull qno
		end
	end
end

def purge
	$specs_rm.each { |fn|
		File.unlink "#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8/#{fn}.gemspec.rz" if File.exist? "#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8/#{fn}.gemspec.rz"
		File.unlink "#{MIRROR_FOLDER}/mirror/gems/#{fn}.gem" if File.exist? "#{MIRROR_FOLDER}/mirror/gems/#{fn}.gem"
	}
end

def finish
	open("#{MIRROR_FOLDER}/failed_gems", "wb") {|f| Marshal.dump $failed_gems, f}
	purge
	EM.stop
end




# prevent mutiple instance running
if File.exist? "#{MIRROR_FOLDER}/sync_lock"
	print "Another mirror process is running!\n"
	exit
end

FileUtils.touch "#{MIRROR_FOLDER}/sync_lock"

at_exit {
	File.unlink "#{MIRROR_FOLDER}/sync_lock"
}


# parse ARGV
$recheck_all_gems = ARGV[0] == "check"



FileUtils.mkdir_p [
	"#{MIRROR_FOLDER}/mirror/gems",
	"#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8",
	"#{MIRROR_FOLDER}/meta_backup"
]

EM.run {
	old_specs = read_metafile

	download_metadata {
		$specs = specs = read_metafile

		begin
			$failed_gems = open("#{MIRROR_FOLDER}/failed_gems", "rb") {|f| Marshal.load f}
		rescue
			$failed_gems = []
		end

		$specs_add = $failed_gems + ($recheck_all_gems ? specs : (specs - old_specs))
		$specs_rm = old_specs - specs

		print "metadata over!\n"

		if $specs_add.empty?
			finish
		else
			$main_dl_queue = []
			100.times { |n| pull(n) }
		end
	}
}

