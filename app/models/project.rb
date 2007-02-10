require 'fileutils'

class Project
  @@plugin_names = []

  def self.plugin(plugin_name)
    @@plugin_names << plugin_name unless RAILS_ENV == 'test' or @@plugin_names.include? plugin_name
  end

  def self.read(dir)
    @project_in_the_works = Project.new(File.basename(dir))
    begin
      return @project_in_the_works.load_config
    rescue => e
      raise "Could not load #{@project_in_the_works.config_file} : #{e.message} in #{e.backtrace.first}"
    ensure
      @project_in_the_works = nil
    end
  end
  
  def self.configure
    raise 'No project is currently being created' unless @project_in_the_works
    yield @project_in_the_works
  end

  attr_reader :name, :plugins, :build_command, :rake_task
  attr_writer :local_checkout 
  attr_accessor :source_control, :path, :scheduler, :builder_status

  def initialize(name, source_control = Subversion.new)
    @name, @source_control = name, source_control

    @path = File.join(Configuration.builds_directory, @name)
    @scheduler = PollingScheduler.new(self)
    @plugins = []
    @plugins_by_name = {}

    instantiate_plugins
  end

  def config_file
    File.expand_path(File.join(path, 'project_config.rb'))
  end

  def load_config
    if File.exists?(config_file)
      load config_file
    end
    self
  end

  def instantiate_plugins
    @@plugin_names.each do |plugin_name|
      plugin_instance = plugin_name.to_s.camelize.constantize.new(self)
      self.add_plugin(plugin_instance)
    end
  end

  def add_plugin(plugin, plugin_name = plugin.class)
    @plugins << plugin
    plugin_name = plugin_name.to_s.underscore.to_sym
    if self.respond_to?(plugin_name)
      raise "Cannot register an plugin with name #{plugin_name.inspect} " +
            "because another plugin, or a method with the same name already exists"
    end
    @plugins_by_name[plugin_name] = plugin
    plugin
  end

  # access plugins by their names
  def method_missing(method_name, *args, &block)
    @plugins_by_name.key?(method_name) ? @plugins_by_name[method_name] : super
  end
  
  # used by rjs to refresh project if build state tag changed.
  def builder_and_build_states_tag
    builder_state_and_activity.gsub(' ', '') + (builds.empty? ? '' : last_build.label.to_s) + last_build_status.to_s
  end
  
  def ==(another)
    another.is_a?(Project) and another.name == self.name
  end

  def build_command=(value)
    raise 'Cannot set build_command when rake_task is already defined' if value and @rake_task
    @build_command = value
  end

  def rake_task=(value)
    raise 'Cannot set rake_task when build_command is already defined' if value and @build_command
    @rake_task = value
  end

  def local_checkout
    @local_checkout or File.join(@path, 'work')
  end

  def builds
    raise "Project #{name.inspect} has no path" unless path

    builds = Dir["#{path}/build-*/build_status.*"].collect do |status_file|
      build_directory = File.basename(File.dirname(status_file))
      build_label = build_directory[6..-1]

      Build.new(self, build_label)
    end

    order_by_label(builds)
  end

  def builder_state       
    ProjectBlocker.blocked?(self) ? Status::RUNNING : Status::NOT_RUNNING
  end
  
  def builder_activity
    state = builder_state
    # the who knows is to fix a broken build, this should be removed - jss
    state == Status::RUNNING ? (@builder_status ? @builder_status.status : 'who knows?') : state
  end
  
  def builder_state_and_activity
    result = builder_state == Status::RUNNING ? builder_activity.to_s : builder_state.downcase
  end 
  
  def last_build
    builds.last
  end

  def find_build(label)
    # this could be optimized a lot
    builds.find { |build| build.label.to_s == label }
  end
    
  def last_build_status
    builds.empty? ? :never_built : last_build.status
  end

  def last_five_builds
    builds.reverse[0..4]
  end

  def build_if_necessary
    notify(:polling_source_control)
    begin
      revisions = new_revisions()
      if revisions.empty?
        notify(:no_new_revisions_detected)
        return nil
      else
        remove_build_requested_flag_file if force_build_requested?
        notify(:new_revisions_detected, revisions)
        return build(revisions)
      end
    rescue => e
      notify(:build_loop_failed, e) rescue nil
      raise
    ensure
      notify(:sleeping) rescue nil
    end
  end

  def new_revisions
    builds.empty? ? [@source_control.latest_revision(self)] :
                    @source_control.revisions_since(self, builds.last.label.to_i)
  end
  
  def force_build_requested?
    File.file?(build_requested_flag_file)
  end
  
  def request_force_build
    result = ''
    begin
      ForceBuildBlocker.block(self)
      unless force_build_requested?
        create_build_requested_flag_file
        result = 'The force build is pending now!'
      else
        result =  'Another build is pending already!'
      end
    rescue => lock_error
      result =  'Another build is pending already!'     
    ensure 
      ForceBuildBlocker.release(self) rescue nil
    end
    return result
  end
  
  def config_modifications?
    build = last_build
    config_file = File.join(path, 'project_config.rb')
    if (!build.nil? and File.exists?(config_file) and (File.mtime(config_file) > build.time))
      notify(:configuration_modified)
      return true
    end
    return false
  end
  
  def force_build_if_requested
    return unless force_build_requested?
    remove_build_requested_flag_file
    begin
      ForceBuildBlocker.block(self)     
      build
    ensure
      ForceBuildBlocker.release(self) rescue nil
    end  
  end
  
  def force_build_request_allowed?
    builder_activity.to_s == "sleeping" and !force_build_requested?
  end

  def build(revisions = [@source_control.latest_revision(self)])   
    previous_build = last_build    
    last_revision = revisions.last
    
    build = Build.new(self, create_build_label(last_revision.number))
    log_changeset(build.artifacts_directory, revisions)
    @source_control.update(self, last_revision)
    notify(:build_started, build)
    build.run
    notify(:build_finished, build)

    if previous_build
      if build.failed? and previous_build.successful?
        notify(:build_broken, build, previous_build)
      elsif build.successful? and previous_build.failed?
        notify(:build_fixed, build, previous_build)
      end
    end

    build    
  end

  def notify(event, *event_parameters)
    errors = []
    results = @plugins.collect do |plugin| 
      begin
        plugin.send(event, *event_parameters) if plugin.respond_to?(event)
      rescue => plugin_error
        CruiseControl::Log.error(plugin_error)
        errors << "#{plugin.class}: #{plugin_error.message}"
      end
    end
    
    if errors.empty?
      return results.compact
    else
      if errors.size == 1
        error_message = "Plugin error: #{errors.first}"
      else
        error_message = "Plugin error:\n" + errors.map { |e| "  #{e}" }.join("\n")
      end
      raise error_message
    end
  end
  
  def log_changeset(artifacts_directory, revisions)
    File.open(File.join(artifacts_directory, 'changeset.log'), 'w') do |f|
      revisions.each { |rev| f << rev.to_s << "\n" }
    end
  end

  def respond_to?(method_name)
    @plugins_by_name.key?(method_name) or super
  end

  def build_requested_flag_file
    File.join(path, 'build_requested')
  end
  
  private
  # sorts a array of builds in order of revision number and rebuild number 
  def order_by_label(builds)
    builds.sort_by do |build|
      number_and_rebuild = build.label.split('.')
      number_and_rebuild.map { |x| x.to_i }
    end
  end
    
  def create_build_label(revision_number)
    revision_number = revision_number.to_s
    build_labels = builds.map { |b| b.label.to_s }
    related_builds_pattern = Regexp.new("^#{Regexp.escape(revision_number)}(\\.\\d+)?$")
    related_builds = build_labels.select { |label| label =~ related_builds_pattern }

    case related_builds
    when [] then revision_number
    when [revision_number] then "#{revision_number}.1"
    else
      rebuild_numbers = related_builds.map { |label| label.split('.')[1] }.compact
      last_rebuild_number = rebuild_numbers.sort_by { |x| x.to_i }.last 
      "#{revision_number}.#{last_rebuild_number.next}"
    end
  end
  
  def create_build_requested_flag_file
    FileUtils.touch(build_requested_flag_file)
  end

  def remove_build_requested_flag_file
    FileUtils.rm_f(Dir[build_requested_flag_file])
  end

end

# TODO make me pretty, move me to another file, invoke me from environment.rb
# TODO check what happens if loading a plugin raises an error (e.g, SyntaxError in plugin/init.rb)

plugin_loader = Object.new

def plugin_loader.load_plugin(plugin_path)
  plugin_file = File.basename(plugin_path).sub(/\.rb$/, '')
  plugin_is_directory = (plugin_file == 'init')  
  plugin_name = plugin_is_directory ? File.basename(File.dirname(plugin_path)) : plugin_file

  CruiseControl::Log.debug("Loading plugin #{plugin_name}")
  if RAILS_ENV == 'development'
    load plugin_path
  else
    if plugin_is_directory then require "#{plugin_name}/init" else require plugin_name end
  end
end

def plugin_loader.load_all
  plugins = Dir[File.join(RAILS_ROOT, 'builder_plugins', 'installed', '*')]

  plugins.each do |plugin|
    if File.file?(plugin)
      if plugin[-3..-1] == '.rb'
        load_plugin(File.basename(plugin))
      else
        # a file without .rb extension, ignore
      end
    elsif File.directory?(plugin)
      # ignore Subversion directory (although it should be considered hidden by Dir[], but just in case)
      next if plugin[-4..-1] == '.svn'
      init_path = File.join(plugin, 'init.rb')
      if File.file?(init_path)
        load_plugin(init_path)
      else
        log.error("No init.rb found in plugin directory #{plugin}")
      end
    else
      # a path is neither file nor directory. whatever else it may be, let's ignore it.
      # TODO: find out what happens with symlinks on a Linux here? how about broken symlinks?
    end
  end

end

plugin_loader.load_all
