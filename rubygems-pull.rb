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
#  Usage: rubygems-pull.rb [check | refreshdep]
#  Run without parameter -> normal mirror sync
#    (Will consume large time when first run)
#    (Full mirror will take approximately 150GB)
#  Run with "check" -> ignore specs difference
#    force to check all gems
#    (only download new & failed gems)
#  Run with "refreshdep" -> update & regenerate dependencies
#    (this will take lots of real time & cpu time)
# ----------------------------------------------------------
#  Keep sync:
#    Just add this script to crontab, or
#    you may wish write a systemd timer if using systemd
#    (You may want to redirect output on crontab)
# ----------------------------------------------------------
#  For detail usage, please read README.md
# ==========================================================
require "rubygems"
require "eventmachine"
require "em-http"
require "fileutils"

require "#{__dir__}/mirror-conf.rb"

# gen mirror download connection
def create_conn
  EM::HttpRequest.new(MIRROR_SOURCE)
end

# download function
def download(fn, conn = nil, retried = false, &block)
  conn = create_conn unless conn
  http = conn.get path: fn, keepalive: true
  file = false # waiting for open file
  http.stream {|chunk|
    if http.response_header.http_status == 200
      file = open("#{MIRROR_FOLDER}/mirror/#{fn}", "wb") unless file
      file.write chunk
    end
  }
  http.callback {
    file.close if file
    yield http.response_header.http_status == 200, conn if block_given?
  }
  http.errback {
    file.close if file
    case http.error
    when 'connection closed by server' # Keep-Alive connection closed, reconnect & download
      conn.unbind rescue nil
      EM.next_tick { download fn, create_conn, false, &block }
    else
      print "DL ERR: #{http.error}\n"
      if retried
        yield false, conn if block_given?
      else
        EM.next_tick { download fn, create_conn, true, &block }
      end
    end
  }
end

# generate gem fullname from spec list item
def gen_fullname(gem)
  "#{gem[0]}-#{gem[1].version}#{"-#{gem[2]}" if gem[2] != "ruby"}"
end

# gem dependency list
def gen_dep(gem_name)
  $specs.select {|g| g[0] == gem_name} .map {|gem|
    gemspec = Marshal.load(Zlib::Inflate.inflate(open("#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8/#{gen_fullname gem}.gemspec.rz", "rb"){|f| f.read}))

    {
      name: gemspec.name,
      number: gemspec.version.version,
      platform: gemspec.platform.to_s, # May be a Gem::Platform instance, need to convert to string
      dependencies: gemspec.dependencies.select{|i| i.type == :runtime}.inject([]) {|res, i|
        req = i.requirement.requirements.map{|r| r.join(" ")}.join(", ")
        case i.name
        when String # normally expected one.......
          res << [i.name, req]
        when Array # fantastic rubygems, you may set mutiple names in a req.......
          i.name.each {|meQAQ|
            res << [meQAQ, req] unless meQAQ.include? " " # do some check to prevent weird things.......
          }
        when Symbol
          res << [i.name.to_s, req]
        else
          # do nothing here, though rubygems.org seems to force .to_s here OwO
        end
        res # alway return this at end to prevent forgotting return res
      }
    }
  }
end

# save dependency data
def save_dep(gem_name, remained = nil)
  open("#{MIRROR_FOLDER}/dep_data/#{gem_name}", "wb") {|f|
    Marshal.dump gen_dep(gem_name), f
    print "#{gem_name} dependency refreshed! #{remained}\n"
  }
rescue => e
  FileUtils.rm_f "#{MIRROR_FOLDER}/dep_data/#{gem_name}" 
  $failed_deps.push gem_name
  print "!!! DEP GEN ERR !!!\n"
  print "Exception: #{$!}\n"
  print "Backtrace:\n\t#{e.backtrace.join("\n\t")}\n"
end

# metadata reader
def read_metafile
  specs = Marshal.load(Gem.gunzip(open("#{MIRROR_FOLDER}/mirror/specs.4.8.gz", "rb"){|f| f.read}))
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
  download(fn) { |res, rcon|
    rcon.unbind rescue nil
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
def pull(qno, conn = nil)
  conn = create_conn unless conn
  PIPELINING_REQ.times {|pno|
    gem = $specs_add.shift
    break unless gem

    # mark as downloading
    $main_dl_queue[qno][pno * 2] = true # for gemspec
    $main_dl_queue[qno][pno * 2 + 1] = true # for gem

    # check for accidently removed gems (?
    $failed_gems.delete gem if $failed_gems.include?(gem) and not $specs.include?(gem)

    fn = gen_fullname gem

    if File.exist? "#{MIRROR_FOLDER}/mirror/gems/#{fn}.gem" and
        File.size? "#{MIRROR_FOLDER}/mirror/gems/#{fn}.gem" and
        File.exist? "#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8/#{fn}.gemspec.rz" and
        File.size? "#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8/#{fn}.gemspec.rz"
      $main_dl_queue[qno][pno * 2] = false
      $main_dl_queue[qno][pno * 2 + 1] = false
      # skip => process as normal download
      EM.next_tick { pull_finish_check conn, qno, pno, gem, fn, true, true }
      next
    end
    download("quick/Marshal.4.8/#{fn}.gemspec.rz", conn) { |res, rcon|
      $main_dl_queue[qno][pno * 2] = false
      print "#{fn}.gemspec.rz download failed!\n" unless res
      pull_finish_check conn, qno, pno, gem, fn, res
    }
    download("gems/#{fn}.gem", conn) { |res|
      $main_dl_queue[qno][pno * 2 + 1] = false
      print "#{fn}.gem download failed!\n" unless res
      pull_finish_check conn, qno, pno, gem, fn, res
    }
  }
end

def pull_finish_check(conn, qno, pno, gem, fn, res, skip = false)
  # add to failed gems when failed
  $failed_gems.push gem if not res and not $failed_gems.include?(gem)
  # per gem finishing process
  unless $main_dl_queue[qno][pno * 2] or $main_dl_queue[qno][pno * 2 + 1]
    print "#{fn} #{skip ? "skipped" : "downloaded"}! #{$specs_add.size}\n"
    $failed_gems.delete gem if $failed_gems.include?(gem) # remove failed gems when succeed
  end
  # when all downloads finished
  unless $main_dl_queue[qno].any?
    if $specs_add.empty? and not $main_dl_queue.flatten.any?
      finish
    else
      $main_dl_queue[qno].clear
      pull qno, conn
    end
  end
end

def purge
  $specs_rm.each { |fn|
    FileUtils.rm_f "#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8/#{fn}.gemspec.rz"
    FileUtils.rm_f "#{MIRROR_FOLDER}/mirror/gems/#{fn}.gem"
  }
end

def update_dep
  gem_names = ($refresh_gen_dep ? $specs : $specs_add_c).collect {|g| g[0]}
  gem_names.uniq!
  size = gem_names.size
  gem_names.each_with_index {|g, n| save_dep g, (size - n)}
end

def finish
  open("#{MIRROR_FOLDER}/failed_gems", "wb") {|f| Marshal.dump $failed_gems, f}
  update_dep if GEN_DEP_DATA
  open("#{MIRROR_FOLDER}/failed_deps", "wb") {|f| Marshal.dump $failed_deps, f}
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
  FileUtils.rm_f "#{MIRROR_FOLDER}/sync_lock"
}


# parse ARGV
$recheck_all_gems = ARGV[0] == "check"
$refresh_gen_dep = ARGV[0] == "refreshdep"



FileUtils.mkdir_p [
  "#{MIRROR_FOLDER}/mirror/gems",
  "#{MIRROR_FOLDER}/mirror/quick/Marshal.4.8",
  "#{MIRROR_FOLDER}/dep_data",
  "#{MIRROR_FOLDER}/meta_backup"
]

EM.run {
  old_specs = read_metafile

  download_metadata {
    $specs = specs = read_metafile

    $failed_gems = open("#{MIRROR_FOLDER}/failed_gems", "rb") {|f| Marshal.load f} rescue []
    $failed_deps = open("#{MIRROR_FOLDER}/failed_deps", "rb") {|f| Marshal.load f} rescue []

    $specs_add = $failed_gems + ($recheck_all_gems ? specs : (specs - old_specs))
    $specs_add_c = $specs_add.dup
    $specs_rm = old_specs - specs

    print "metadata over!\n"

    if $specs_add.empty?
      finish
    else
      $main_dl_queue = Array.new(DL_CONNECTIONS) { [] } # will... init array with array in a block OwO
      DL_CONNECTIONS.times { |n| pull(n) }
    end
  }
}

