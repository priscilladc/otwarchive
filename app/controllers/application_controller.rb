PROFILER_SESSIONS_FILE = 'used_tags.txt'

class ApplicationController < ActionController::Base

  helper :all # include all helpers, all the time

  include ExceptionNotification::Notifiable

  include SanitizeParams
  before_filter :sanitize_params

  # store previous page in session to make redirecting back possible
  before_filter :store_location
  def store_location
    session[:return_to] = request.request_uri
  end
  
  # Authlogic login helpers
  helper_method :current_user
  helper_method :current_admin
  helper_method :logged_in?
  helper_method :logged_in_as_admin?
  
private
  def current_user_session
    return @current_user_session if defined?(@current_user_session)
    @current_user_session = UserSession.find
  end
  
  def current_user
    @current_user = current_user_session && current_user_session.record
  end
  
  def current_admin_session
    return @current_admin_session if defined?(@current_admin_session)
    @current_admin_session = AdminSession.find
  end
  
  def current_admin
    @current_admin = current_admin_session && current_admin_session.record
  end
  
  def logged_in? 
    current_user.nil? ? false : true
  end
  
  def logged_in_as_admin?
    current_admin.nil? ? false : true
  end
  

public

  # Filter method - keeps users out of admin areas
  def admin_only
    logged_in_as_admin? || admin_only_access_denied
  end

  def admin_only_access_denied
    flash[:error] = "I'm sorry, only an admin can look at that area." 
    redirect_to root_path
    false
  end

  # Filter method - prevents users from logging in as admin
  def user_logout_required
    if logged_in?
      flash[:notice] = 'Please log out of your user account first!'
      redirect_to root_path
    end
  end
  
  # Prevents admin from logging in as users
  def admin_logout_required
    if logged_in_as_admin?
      flash[:notice] = 'Please log out of your admin account first!'
      redirect_to root_path
    end
  end
  
  
  # Store the current user as a class variable in the User class,
  # so other models can access it with "User.current_user"
  before_filter :set_current_user
  def set_current_user
    User.current_user = logged_in_as_admin? ? current_admin : current_user
    @current_user = current_user
  end

  def load_collection
    @collection = Collection.find_by_name(params[:collection_id]) if params[:collection_id]
  end

  def collection_maintainers_only
    logged_in? && @collection && @collection.user_is_maintainer?(current_user) || access_denied
  end

  def collection_owners_only
    logged_in? && @collection && @collection.user_is_owner?(current_user) || access_denied
  end

  @over_anon_threshold = true if @over_anon_threshold.nil?

  def get_page_title(fandom, author, title, options = {})
    # truncate any piece that is over 15 chars long to the nearest word
    if options[:truncate]
      fandom = fandom.gsub(/^(.{15}[\w.]*)(.*)/) {$2.empty? ? $1 : $1 + '...'}
      author = author.gsub(/^(.{15}[\w.]*)(.*)/) {$2.empty? ? $1 : $1 + '...'}
      title = title.gsub(/^(.{15}[\w.]*)(.*)/) {$2.empty? ? $1 : $1 + '...'}
    end

    @page_title = ""
    if logged_in? && !current_user.preference.try(:work_title_format).blank?
      @page_title = current_user.preference.work_title_format
      @page_title.gsub!(/FANDOM/, fandom)
      @page_title.gsub!(/AUTHOR/, author)
      @page_title.gsub!(/TITLE/, title)
    else
      @page_title = title + " - " + author + " - " + fandom
    end
    
    @page_title += " [#{ArchiveConfig.APP_NAME}]" unless options[:omit_archive_name]
    @page_title
  end

  ### GLOBALIZATION ###

#  before_filter :load_locales
#  before_filter :set_preferred_locale

#  I18n.backend = I18nDB::Backend::DBBased.new
#  I18n.record_missing_keys = false # if you want to record missing translations

  protected

  def load_locales
    @loaded_locales ||= Locale.all(:order => :iso)
  end

  # Sets the locale
  def set_preferred_locale
    # Loading the current locale
    if session[:locale] && @loaded_locales.detect { |loc| loc.iso == session[:locale]}
      set_locale session[:locale].to_sym
    else
      set_locale Locale.find_main_cached.iso.to_sym
    end
    @current_locale = Locale.find_by_iso(I18n.locale.to_s)
  end

  ### -- END GLOBALIZATION -- ###

  public

  #### -- AUTHORIZATION -- ####

  # It is just much easier to do this here than to try to stuff variable values into a constant in environment.rb
  before_filter :set_redirects
  def set_redirects
    @logged_in_redirect = url_for(current_user) if current_user.is_a?(User)
    @logged_out_redirect = url_for({:controller => 'session', :action => 'new'})
  end

  def is_registered_user?
    logged_in? || logged_in_as_admin?
  end

  def is_admin?
    logged_in_as_admin?
  end

  def see_adult?
    return true if session[:adult] || logged_in_as_admin?
    return false if current_user == :false
    return true if current_user.is_author_of?(@work)
    return true if current_user.preference && current_user.preference.adult
    return false
  end

  protected

  # Prevents banned and suspended users from adding/editing content
  def check_user_status
    if current_user.is_a?(User) && (current_user.suspended? || current_user.banned?)
      if current_user.suspended?
        flash[:error] = t('suspension_notice', :default => "Your account has been suspended. You may not add or edit content until your suspension has been resolved. Please contact us for more information.")
     else
        flash[:error] = t('ban_notice', :default => "Your account has been banned. You are not permitted to add or edit archive content. Please contact us for more information.")
     end
      redirect_to current_user
    end
  end

  # Does the current user own a specific object?
  def current_user_owns?(item)
  	!item.nil? && current_user.is_a?(User) && (item.is_a?(User) ? current_user == item : current_user.is_author_of?(item))
  end

  # Make sure a specific object belongs to the current user and that they have permission
  # to view, edit or delete it
  def check_ownership
  	access_denied(:redirect => @check_ownership_of) unless current_user_owns?(@check_ownership_of)
  end

  # Make sure the user is allowed to see a specific page
  # includes a special case for restricted works and series, since we want to encourage people to sign up to read them
  def check_visibility
    if @check_visibility_of.respond_to?(:restricted) && @check_visibility_of.restricted && User.current_user == :false
      redirect_to new_session_path(:restricted => true)
    elsif @check_visibility_of.is_a? Skin
      access_denied unless logged_in_as_admin? || current_user_owns?(@check_visibility_of) || @check_visibility_of.official?
    else
      is_hidden = @check_visibility_of.respond_to?(:visible) ? !@check_visibility_of.visible : @check_visibility_of.hidden_by_admin?
      can_view_hidden = logged_in_as_admin? || current_user_owns?(@check_visibility_of)
      access_denied if (is_hidden && !can_view_hidden)
    end
  end

  private
 # With thanks from here: http://blog.springenwerk.com/2008/05/set-date-attribute-from-dateselect.html
  def convert_date(hash, date_symbol_or_string)
    attribute = date_symbol_or_string.to_s
    return Date.new(hash[attribute + '(1i)'].to_i, hash[attribute + '(2i)'].to_i, hash[attribute + '(3i)'].to_i)
  end

  public

  # with thanks to http://henrik.nyh.se/2008/07/rails-404
  def render_optional_error_file(status_code)
    case(status_code)
      when :not_found then
        render :template => "errors/404", :layout => 'application', :status => 404
      when :forbidden then
        render :template => "errors/403", :layout => 'application', :status => 403
      when :unprocessable_entity then
        render :template => "errors/422", :layout => 'application', :status => 422
      when :internal_server_error then
        render :template => "errors/500", :layout => 'application', :status => 500
      else
        super
    end
  end

  def valid_sort_column(param, model='work')
    allowed = []
    if model.to_s.downcase == 'work'
      allowed = ['author', 'title', 'date', 'word_count', 'hit_count']
    elsif model.to_s.downcase == 'tag'
      allowed = ['name', 'created_at', 'suggested_fandoms', 'taggings_count']
    elsif model.to_s.downcase == 'collection'
      allowed = ['title', 'created_at', 'count']
    end
    !param.blank? && allowed.include?(param.to_s.downcase)
  end

  def valid_sort_direction(param)
    !param.blank? && ['asc', 'desc'].include?(param.to_s.downcase)
  end

  #### -- AUTHORIZATION -- ####

  protect_from_forgery

end
