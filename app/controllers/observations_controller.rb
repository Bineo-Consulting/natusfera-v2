#encoding: utf-8
class ObservationsController < ApplicationController
  caches_page :tile_points
  OBS_LIMIT = 20000  
  WIDGET_CACHE_EXPIRATION = 15.minutes
  caches_action :index, :by_login, :project,
    :expires_in => WIDGET_CACHE_EXPIRATION,
    :cache_path => Proc.new {|c| c.params.merge(:locale => I18n.locale)},
    :if => Proc.new {|c| 
      c.session.blank? && # make sure they're logged out
      c.request.format && # make sure format corresponds to a known mime type
      (c.request.format.geojson? || c.request.format.widget? || c.request.format.kml?) && 
      c.request.url.size < 250}
  caches_action :of,
    :expires_in => 1.day,
    :cache_path => Proc.new {|c| c.params.merge(:locale => I18n.locale)},
    :if => Proc.new {|c| c.request.format != :html }
  cache_sweeper :observation_sweeper, :only => [:create, :update, :destroy]
  
  rescue_from ::AbstractController::ActionNotFound  do
    unless @selected_user = User.find_by_login(params[:action])
      return render_404
    end
    by_login
  end

  doorkeeper_for :create, :update, :destroy, :viewed_updates, :update_fields, :if => lambda { authenticate_with_oauth? }
  
  before_filter :load_user_by_login, :only => [:by_login, :by_login_all]
  before_filter :return_here, :only => [:index, :by_login, :show, :id_please, 
    :import, :export, :add_from_list, :new, :project]
  before_filter :authenticate_user!,
                :unless => lambda { authenticated_with_oauth? },
                :except => [:explore,
                            :index,
                            :of,
                            :show,
                            :by_login,
                            :id_please,
                            :tile_points,
                            :nearby,
                            :widget,
                            :project,
                            :stats,
                            :taxa,
                            :taxon_stats,
                            :user_stats,
                            :community_taxon_summary,
                            :map, :add_identification, :identify]
  load_only = [ :show, :edit, :edit_photos, :update_photos, :destroy,
    :fields, :viewed_updates, :community_taxon_summary, :update_fields]
  before_filter :load_observation, :only => load_only
  blocks_spam :only => load_only, :instance => :observation
  before_filter :require_owner, :only => [:edit, :edit_photos,
    :update_photos, :destroy]
  before_filter :curator_required, :only => [:curation, :accumulation, :phylogram]
  before_filter :load_photo_identities, :only => [:new, :new_batch, :show,
    :new_batch_csv,:edit, :update, :edit_batch, :create, :import, 
    :import_photos, :import_sounds, :new_from_list]
  before_filter :load_sound_identities, :only => [:new, :new_batch, :show,
    :new_batch_csv,:edit, :update, :edit_batch, :create, :import, 
    :import_photos, :import_sounds, :new_from_list]
  before_filter :photo_identities_required, :only => [:import_photos]
  after_filter :refresh_lists_for_batch, :only => [:create, :update]
  
  MOBILIZED = [:add_from_list, :nearby, :add_nearby, :project, :by_login, :index, :show]
  before_filter :unmobilized, :except => MOBILIZED
  before_filter :mobilized, :only => MOBILIZED
  before_filter :load_prefs, :only => [:index, :project, :by_login]
  
  ORDER_BY_FIELDS = %w"created_at observed_on project species_guess"
  REJECTED_FEED_PARAMS = %w"page view filters_open partial action id locale"
  REJECTED_KML_FEED_PARAMS = REJECTED_FEED_PARAMS + %w"swlat swlng nelat nelng BBOX"
  MAP_GRID_PARAMS_TO_CONSIDER = REJECTED_KML_FEED_PARAMS +
    %w"order order_by taxon_id taxon_name project_id user_id utf8"
  DISPLAY_ORDER_BY_FIELDS = {
    'created_at' => 'date added',
    'observations.id' => 'date added',
    'id' => 'date added',
    'observed_on' => 'date observed',
    'species_guess' => 'species name',
    'project' => "date added to project"
  }
  PARTIALS = %w(cached_component observation_component observation mini project_observation)
  EDIT_PARTIALS = %w(add_photos)
  PHOTO_SYNC_ATTRS = [:description, :species_guess, :taxon_id, :observed_on,
    :observed_on_string, :latitude, :longitude, :place_guess]

  # GET /observations
  # GET /observations.xml
  def index
    search_params, find_options = get_search_params(params)
    search_params = site_search_params(search_params)

    obsLimit = @prefs["observations_limits"].to_i

    if logged_in? && current_user.has_role?(:admin)
      Rails.logger.info 'Admin power'
    elsif logged_in? && current_user.has_role?(:exporter)
      if find_options[:page] && find_options[:per_page]
        nitems = obsLimit
        if find_options[:page].to_i * find_options[:per_page].to_i > nitems
          if request.format == :json
            render json: {message: "You reach #{nitems} items limit"}, status: 403
            return false
          end
        end
      end
    elsif find_options[:page] && find_options[:per_page]
      if find_options[:page].to_i * find_options[:per_page].to_i > 20000
        if !logged_in? && request.format == :html
          authenticate_user!
          return false
        elsif request.format == :json
          render json: {message: 'You reach 20,000 items limit'}, status: 403
          return false
        end
      end
    end

    if search_params[:q].blank?
      @observations = if perform_caching && (!logged_in? || find_options[:page] == 1)
        cache_params = params.reject{|k,v| %w(controller action format partial).include?(k.to_s)}
        cache_params[:page] ||= 1
        cache_params[:per_page] ||= find_options[:per_page]
        cache_params[:site_name] ||= SITE_NAME if CONFIG.site_only_observations
        cache_params[:bounds] ||= CONFIG.bounds if CONFIG.bounds
        cache_key = "obs_index_#{Digest::MD5.hexdigest(cache_params.to_s)}"
        Rails.cache.fetch(cache_key, :expires_in => 5.minutes) do
          get_paginated_observations(search_params, find_options).to_a
        end
      else
        get_paginated_observations(search_params, find_options)
      end
    else
      @observations = search_observations(search_params, find_options)
    end

    respond_to do |format|
Rails.logger.info '-'* 100
Rails.logger.info 'RESPOND_TO' 
      format.html do
        @iconic_taxa ||= []
        grid_affecting_params = request.query_parameters.reject{ |k,v|
          MAP_GRID_PARAMS_TO_CONSIDER.include?(k.to_s) }
        # there are no parameters at all, so we can show the grid for all taxa
        @map_grid_params = { }
        if grid_affecting_params.blank?
          @display_map_grid = true
        # we can only show grids when quality_grade = 'any',
        # and all other parameters are empty
        elsif grid_affecting_params.delete("quality_grade") == "any" &&
          grid_affecting_params.detect{ |k,v| v != "" }.nil?
          @display_map_grid = true
        end
        # if we are showing a grid
        if @display_map_grid
          @map_grid_params.merge!({
            taxon_id: (search_params[:taxon] ? search_params[:taxon].id : nil),
            user_id: search_params[:user_id],
            project_id: search_params[:project_id],
            place_id: search_params[:place_id]
          }.delete_if{ |k,v| v.nil? })
          if search_params[:taxon] && search_params[:taxon].iconic_taxon
            @map_grid_params[:iconic_taxon] = search_params[:taxon].iconic_taxon.name
          end
        end
        if (partial = params[:partial]) && PARTIALS.include?(partial)
          pagination_headers_for(@observations)
          return render_observations_partial(partial)
        end
      end

      format.json do
        render_observations_to_json
      end
      
      format.mobile
      
      format.geojson do
        render :json => @observations.to_geojson(:except => [
          :geom, :latitude, :longitude, :map_scale, 
          :num_identification_agreements, :num_identification_disagreements, 
          :delta, :location_is_exact])
      end
      
      format.atom do
        @updated_at = Observation.first(:order => 'updated_at DESC').updated_at
      end
      
      format.dwc

      format.csv do
        render_observations_to_csv
      end
      
      format.kml do
        render_observations_to_kml(
          :snippet => "#{CONFIG.site_name} Feed for Everyone", 
          :description => "#{CONFIG.site_name} Feed for Everyone", 
          :name => "#{CONFIG.site_name} Feed for Everyone"
        )
      end
      
      format.widget do
        if params[:markup_only] == 'true'
          render :js => render_to_string(:partial => "widget.html.erb", :locals => {
            :show_user => true, :target => params[:target], :default_image => params[:default_image], :silence => params[:silence]
          })
        else
          render :js => render_to_string(:partial => "widget.js.erb", :locals => {
            :show_user => true
          })
        end
      end
    end
  end

def getUser(token)
  # token = "f8cf54de29268054c858accee17e13194e1b8bfa"
  urlInfo = "https://www.authenix.eu/oauth/tokeninfo"
  clientId = "df4b4fd7-f57c-5c1c-10ce-84dfdbb495a3"
  clientSecret = "0bd623bdcc5467595c70466c2d755b5821bd14d6b7aa9d8ea6fb0bff716ed0e7"
  data = "token=#{token}&token_type_hint=access_token"
  res = `curl -X POST #{urlInfo} -u #{clientId}:#{clientSecret} -H "accept: application/json" -H "Content-Type: application/x-www-form-urlencoded" -d "#{data}"`

  aux = JSON.parse(res)
  if (aux['active']) 
    return aux['username']
  else
    return nil
  end
end


  def add_identification
    #observation_id: 279488,
    #taxon_id: 942,
    #user_id: 4032,
    #type: nil,
    #body: nil,
    if params[:taxon]
      i1 = Identification.new
      i1.observation_id = params[:observation_id]
      i1.taxon_id = (Taxon.search params[:taxon].split(/[ _-]/)[0..1]).first.id #params[:taxon_id]
      i1.user_id = 1
      i1.origin = getUser(params[:token]) #params[:type]
      i1.body = params[:body] or "by Cos4Cloud"
      i1.save
      render :json => {i1: i1, errors: i1.errors.messages.to_s}
    else
      i1 = Comment.new
      i1.parent_id = params[:observation_id]
      i1.parent_type = 'Observation'
      i1.user_id = 1
      i1.origin = getUser(params[:token]) #params[:type]
      i1.body = params[:body] or "by Cos4Cloud"
      i1.save
      render :json => {i1: i1, errors: i1.errors.messages.to_s}
    end
  end



  def identify
    @observation = Observation.find(params[:id], :include => [ :quality_metrics,
                    :photos,
                    :identifications,
                    { :taxon => :taxon_names }
      ])
    photo = @observation.observation_photos.first.photo.medium_url.sub 'http://', 'https://'

    urlStr = 'https://my-api.plantnet.org/v2/identify/all?';
    params = "images=#{URI.escape(photo)}&organs=flower&lang=en&api-key=2a10HwuT6PvsSXZFYhBwzlsXO"
    url = URI(urlStr)
    url.query = params

    net = Net::HTTP.new(url.host, 443)
    net.use_ssl = true
    res = net.get(url.to_s)
    json = JSON.parse res.body
    taxon = json["results"][0]["species"]["scientificNameWithoutAuthor"]
    score = json["results"][0]["score"] * 100

    taxa = (Taxon.search taxon.split(/[ _-]/)[0..1])
    if taxa.empty?
      taxa = (Taxon.search taxon.split(/[ _-]/)[0])
    end
    
    if (not taxa.empty?)
      i1 = Identification.new
      i1.observation_id = @observation.id
      i1.taxon_id = taxa.first.id
      i1.user_id = 2
      score = score.round(1)
      i1.body = "#{taxon} #{score}\% by PlantNet"
      i1.save
      return render :json => {ok: true, i1: i1, errors: i1.errors.messages.to_s}
    end
    render :json => {ok: false}
  end 
 
  def of
    if request.format == :html
      redirect_to observations_path(:taxon_id => params[:id])
      return
    end
    unless @taxon = Taxon.find_by_id(params[:id].to_i)
      render_404 && return
    end
    @observations = Observation.of(@taxon).all(
      :include => [ :user,
                    :iconic_taxon,
                    { :taxon => :taxon_descriptions },
                    { :observation_photos => :photo } ],
      :order => "observations.id desc", 
      :limit => 500).sort_by{|o| [o.quality_grade == "research" ? 1 : 0, o.id]}
    respond_to do |format|
      format.json do
        render :json => @observations.to_json(
          :methods => [ :user_login, :iconic_taxon_name, :obs_image_url],
          :include => [ { :user => { :only => :login } },
                        :taxon, :iconic_taxon ] )
        end
      format.geojson do
        render :json => @observations.to_geojson(:except => [
          :geom, :latitude, :longitude, :map_scale, 
          :num_identification_agreements, :num_identification_disagreements, 
          :delta, :location_is_exact])
      end
    end
  end
  
  # GET /observations/1
  # GET /observations/1.xml
  def show
    if request.format == :html && 
        params[:partial] == "cached_component" && 
        fragment_exist?(@observation.component_cache_key(:for_owner => @observation.user_id == current_user.try(:id)))
      return render(:partial => params[:partial], :object => @observation,
        :layout => false)
    end
    
    @previous = @observation.user.observations.first(:conditions => ["id < ?", @observation.id], :order => "id DESC")
    @prev = @previous
    @next = @observation.user.observations.first(:conditions => ["id > ?", @observation.id], :order => "id ASC")
    @quality_metrics = @observation.quality_metrics.all(:include => :user)
    if logged_in?
      @user_quality_metrics = @observation.quality_metrics.select{|qm| qm.user_id == current_user.id}
      @project_invitations = @observation.project_invitations.limit(100).to_a
      @project_invitations_by_project_id = @project_invitations.index_by(&:project_id)
    end
    @coordinates_viewable = @observation.coordinates_viewable_by?(current_user)
    
    respond_to do |format|
      format.html do
        # always display the time in the zone in which is was observed
        Time.zone = @observation.user.time_zone
                
        @identifications = @observation.identifications.includes(:user, :taxon => :photos)
        @current_identifications = @identifications.select{|o| o.current?}
        @owners_identification = @current_identifications.detect do |ident|
          ident.user_id == @observation.user_id
        end
        @community_identification = if @observation.community_taxon
          Identification.new(:taxon => @observation.community_taxon, :observation => @observation)
        end

        if logged_in?
          @viewers_identification = @current_identifications.detect do |ident|
            ident.user_id == current_user.id
          end
        end
        
        @current_identifications_by_taxon = @current_identifications.select do |ident|
          ident.user_id != ident.observation.user_id
        end.group_by{|i| i.taxon}
        @sorted_current_identifications_by_taxon = @current_identifications_by_taxon.sort_by do |row|
          row.last.size
        end.reverse
        
        if logged_in?
          @projects = Project.all(
            :joins => [:project_users], 
            :limit => 1000, 
            :conditions => ["project_users.user_id = ?", current_user]
          ).sort_by{|p| p.title.downcase}
        end
        
        @places = @observation.places
        
        @project_observations = @observation.project_observations.limit(100).to_a
        @project_observations_by_project_id = @project_observations.index_by(&:project_id)
        
        @comments_and_identifications = (@observation.comments.all + 
          @identifications).sort_by{|r| r.created_at}
        
        @photos = @observation.observation_photos.includes(:photo => [:flags]).sort_by do |op| 
          op.position || @observation.observation_photos.size + op.id.to_i
        end.map{|op| op.photo}.compact
        @flagged_photos = @photos.select{|p| p.flagged?}
        @sounds = @observation.sounds.all
        
        if @observation.observed_on
          @day_observations = Observation.by(@observation.user).on(@observation.observed_on)
            .includes([ :photos, :user ])
            .paginate(:page => 1, :per_page => 14)
        end
        
        if logged_in?
          @subscription = @observation.update_subscriptions.first(:conditions => {:user_id => current_user})
        end
        
        @observation_links = @observation.observation_links.sort_by{|ol| ol.href}
        @posts = @observation.posts.published.limit(50)

        if @observation.taxon
          unless @places.blank?
            @listed_taxon = ListedTaxon.
              includes(:place).
              where("taxon_id = ? AND place_id IN (?) AND establishment_means IS NOT NULL", @observation.taxon_id, @places).
              order("establishment_means IN ('endemic', 'introduced') DESC, places.bbox_area ASC").first
            @conservation_status = ConservationStatus.
              where(:taxon_id => @observation.taxon).where("place_id IN (?)", @places).
              where("iucn >= ?", Taxon::IUCN_NEAR_THREATENED).
              includes(:place).first
          end
          @conservation_status ||= ConservationStatus.where(:taxon_id => @observation.taxon).where("place_id IS NULL").
            where("iucn >= ?", Taxon::IUCN_NEAR_THREATENED).first
        end

        @observer_provider_authorizations = @observation.user.provider_authorizations
        @shareable_image_url = if !@photos.blank? && photo = @photos.detect{|p| p.medium_url =~ /^http/}
          FakeView.image_url(photo.best_url(:original))
        else
          FakeView.iconic_taxon_image_url(@observation.taxon, :size => 200)
        end
        @shareable_description = @observation.to_plain_s(:no_place_guess => !@coordinates_viewable)
        @shareable_description += ".\n\n#{@observation.description}" unless @observation.description.blank?
        

        if logged_in?
          user_viewed_updates
        end
        
        if params[:partial]
          return render(:partial => params[:partial], :object => @observation,
            :layout => false)
        end
      end
      
      format.mobile
       
      format.xml { render :xml => @observation }
      
      format.json do
        taxon_options = Taxon.default_json_options
        taxon_options[:methods] += [:iconic_taxon_name, :image_url, :common_name, :default_name]
        render :json => @observation.to_json(
          :viewer => current_user,
          :methods => [:user_login, :iconic_taxon_name],
          :include => {
            :observation_field_values => {:include => {:observation_field => {:only => [:name]}}},
            :project_observations => {
              :include => {
                :project => {
                  :only => [:id, :title],
                  :methods => [:icon_url]
                }
              }
            },
            :observation_photos => {
              :include => {
                :photo => {
                  :methods => [:license_code, :attribution],
                  :except => [:original_url, :file_processing, :file_file_size, 
                    :file_content_type, :file_file_name, :mobile, :metadata, :user_id, 
                    :native_realname, :native_photo_id]
                }
              }
            },
            :comments => {
              :include => {
                :user => {
                  :only => [:name, :login, :id],
                  :methods => [:user_icon_url]
                }
              }
            },
            :taxon => taxon_options,
            :identifications => {
              :include => {
                :user => {
                  :only => [:name, :login, :id],
                  :methods => [:user_icon_url]
                },
                :taxon => taxon_options
              }
            }
          })
      end
      
      format.atom do
        cache
      end
    end
  end

  # GET /observations/new
  # GET /observations/new.xml
  # An attempt at creating a simple new page for batch add
  def new
    @observation = Observation.new(:user => current_user)
    @observation.id_please = params[:id_please]
    @observation.time_zone = current_user.time_zone

    if params[:copy] && (copy_obs = Observation.find_by_id(params[:copy])) && copy_obs.user_id == current_user.id
      %w(observed_on_string time_zone place_guess geoprivacy map_scale positional_accuracy).each do |a|
        @observation.send("#{a}=", copy_obs.send(a))
      end
      @observation.latitude = copy_obs.private_latitude || copy_obs.latitude
      @observation.longitude = copy_obs.private_longitude || copy_obs.longitude
      copy_obs.observation_photos.each do |op|
        @observation.observation_photos.build(:photo => op.photo)
      end
      copy_obs.observation_field_values.each do |ofv|
        @observation.observation_field_values.build(:observation_field => ofv.observation_field, :value => ofv.value)
      end
    end
    
    @taxon = Taxon.find_by_id(params[:taxon_id].to_i) unless params[:taxon_id].blank?
    unless params[:taxon_name].blank?
      @taxon ||= TaxonName.first(:conditions => [
        "lower(name) = ?", params[:taxon_name].to_s.strip.gsub(/[\s_]+/, ' ').downcase]
      ).try(:taxon)
    end
    
    if !params[:project_id].blank?
      @project = if params[:project_id].to_i == 0
        Project.includes(:project_observation_fields => :observation_field).find(params[:project_id])
      else
        Project.includes(:project_observation_fields => :observation_field).find_by_id(params[:project_id].to_i)
      end
      if @project
        @place = @project.place
        @project_curators = @project.project_users.where("role IN (?)", [ProjectUser::MANAGER, ProjectUser::CURATOR])
        @tracking_code = params[:tracking_code] if @project.tracking_code_allowed?(params[:tracking_code])
        @kml_assets = @project.project_assets.select{|pa| pa.asset_file_name =~ /\.km[lz]$/}
      end
    end

    @place ||= Place.find(params[:place_id]) unless params[:place_id].blank? rescue nil

    if @place
      @place_geometry = PlaceGeometry.without_geom.first(:conditions => {:place_id => @place})
    end
    
    if params[:facebook_photo_id]
      begin
        sync_facebook_photo
      rescue Koala::Facebook::APIError => e
        raise e unless e.message =~ /OAuthException/
        redirect_to ProviderAuthorization::AUTH_URLS['facebook']
        return
      end
    end
    sync_flickr_photo if params[:flickr_photo_id] && current_user.flickr_identity
    sync_picasa_photo if params[:picasa_photo_id] && current_user.picasa_identity
    sync_local_photo if params[:local_photo_id]
      
    @welcome = params[:welcome]
    
    # this should happen AFTER photo syncing so params can override attrs 
    # from the photo
    [:latitude, :longitude, :place_guess, :location_is_exact, :map_scale,
        :positional_accuracy, :positioning_device, :positioning_method,
        :observed_on_string].each do |obs_attr|
      next if params[obs_attr].blank?
      # sync_photo indicates that the user clicked sync photo, so presumably they'd 
      # like the photo attrs to override the URL
      # invite links are the other case, in which URL params *should* override the 
      # photo attrs b/c the person who made the invite link chose a taxon or something
      if params[:sync_photo]
        @observation.send("#{obs_attr}=", params[obs_attr]) if @observation.send(obs_attr).blank?
      else
        @observation.send("#{obs_attr}=", params[obs_attr])
      end
    end
    if @taxon
      @observation.taxon = @taxon
      @observation.species_guess = if @taxon.common_name
        @taxon.common_name.name
      else 
        @taxon.name
      end
    elsif !params[:taxon_name].blank?
      @observation.species_guess =  params[:taxon_name]
    end
    
    @observation_fields = ObservationField.recently_used_by(current_user).limit(10)
    
    respond_to do |format|
      format.html do
        @observations = [@observation]
        @sharing_authorizations = current_user.provider_authorizations.select do |pa|
          pa.provider_name == "facebook" || (pa.provider_name == "twitter" && !pa.secret.blank?)
        end
      end
      format.json  { render :json => @observation }
    end
  end
  
  # def quickadd
  #   if params[:txt]
  #     pieces = txt.split(/\sat\s|\son\s|\sin\s/)
  #     @observation = Observation.new(:species_guess => pieces.first)
  #     @observation.place_guess = pieces.last if pieces.size > 1
  #     if pieces.size > 2
  #       @observation.observed_on_string = pieces[1..-2].join(' ')
  #     end
  #     @observation.user = self.current_user
  #   end
  #   respond_to do |format|
  #     if @observation.save
  #       flash[:notice] = "Your observation was saved."
  #       format.html { redirect_to :action => @user.login }
  #       format.xml  { render :xml => @observation, :status => :created, 
  #                            :location => @observation }
  #       format.js   { render }
  #     else
  #       format.html { render :action => "new" }
  #       format.xml  { render :xml => @observation.errors, 
  #                            :status => :unprocessable_entity }
  #       format.js   { render :json => @observation.errors, 
  #                            :status => :unprocessable_entity }
  #     end
  #   end
  # end
  
  # GET /observations/1/edit
  def edit
    # Only the owner should be able to see this.  
    unless current_user.id == @observation.user_id or current_user.is_admin?
      redirect_to observation_path(@observation)
      return
    end
    
    # Make sure user is editing the REAL coordinates
    if @observation.coordinates_obscured?
      @observation.latitude = @observation.private_latitude
      @observation.longitude = @observation.private_longitude
    end
    
    if params[:facebook_photo_id]
      begin
        sync_facebook_photo
      rescue Koala::Facebook::APIError => e
        raise e unless e.message =~ /OAuthException/
        redirect_to ProviderAuthorization::AUTH_URLS['facebook']
        return
      end
    end
    sync_flickr_photo if params[:flickr_photo_id]
    sync_picasa_photo if params[:picasa_photo_id]
    sync_local_photo if params[:local_photo_id]
    @observation_fields = ObservationField.recently_used_by(current_user).limit(10)

    if @observation.quality_metrics.detect{|qm| qm.user_id == @observation.user_id && qm.metric == QualityMetric::WILD && !qm.agree?}
      @observation.captive_flag = true
    end

    respond_to do |format|
      format.html do
        if params[:partial] && EDIT_PARTIALS.include?(params[:partial])
          return render(:partial => params[:partial], :object => @observation,
            :layout => false)
        end
      end
    end
  end

  # POST /observations
  # POST /observations.xml
  def create
    # Handle the case of a single obs
    params[:observations] = [['0', params[:observation]]] if params[:observation]
    
    if params[:observations].blank? && params[:observation].blank?
      respond_to do |format|
        format.html do
          flash[:error] = t(:no_observations_submitted)
          redirect_to new_observation_path
        end
        format.json { render :status => :unprocessable_entity, :json => "No observations submitted!" }
      end
      return
    end
    
    @observations = params[:observations].map do |fieldset_index, observation|
      next if observation.blank?
      observation.delete('fieldset_index') if observation[:fieldset_index]
      o = unless observation[:uuid].blank?
        current_user.observations.where(:uuid => observation[:uuid]).first
      end
      o ||= Observation.new
      o.assign_attributes(observation)
      o.user = current_user
      o.user_agent = request.user_agent
      o.site = @site || current_user.site
      if doorkeeper_token && (a = doorkeeper_token.application)
        o.oauth_application = a.becomes(OauthApplication)
      end
      # Get photos
      puts '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'
      Rails.logger.error "[PHOTOS #{o.inspect}]"
      puts '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'

      Photo.descendent_classes.each do |klass|
        klass_key = klass.to_s.underscore.pluralize.to_sym
        if params[klass_key] && params[klass_key][fieldset_index]
          o.photos << retrieve_photos(params[klass_key][fieldset_index], 
            :user => current_user, :photo_class => klass)
        end
        if params["#{klass_key}_to_sync"] && params["#{klass_key}_to_sync"][fieldset_index]
          if photo = o.photos.compact.last
            photo_o = photo.to_observation
            PHOTO_SYNC_ATTRS.each do |a|
              o.send("#{a}=", photo_o.send(a)) if o.send(a).blank?
            end
          end
        end
      end
      o.sounds << Sound.from_observation_params(params, fieldset_index, current_user)
      o
    end
    
    current_user.observations << @observations.compact
    
    if request.format != :json && !params[:accept_terms] && params[:project_id] && !current_user.project_users.find_by_project_id(params[:project_id])
      flash[:error] = t(:but_we_didnt_add_this_observation_to_the_x_project, :project => Project.find_by_id(params[:project_id]).title)
    else
      create_project_observations
    end
    update_user_account
    
    # check for errors
    errors = false
    @observations.compact.each { |obs| errors = true unless obs.valid? }
    respond_to do |format|
      format.html do
        unless errors
          flash[:notice] = params[:success_msg] || t(:observations_saved)
          if params[:commit] == t(:save_and_add_another)
            o = @observations.first
            redirect_to :action => 'new', 
              :latitude => o.coordinates_obscured? ? o.private_latitude : o.latitude, 
              :longitude => o.coordinates_obscured? ? o.private_longitude : o.longitude, 
              :place_guess => o.place_guess, 
              :observed_on_string => o.observed_on_string,
              :location_is_exact => o.location_is_exact,
              :map_scale => o.map_scale,
              :positional_accuracy => o.positional_accuracy,
              :positioning_method => o.positioning_method,
              :positioning_device => o.positioning_device,
              :project_id => params[:project_id]
          elsif @observations.size == 1
            redirect_to observation_path(@observations.first)
          else
            redirect_to :action => self.current_user.login
          end
        else
          if @observations.size == 1
            render :action => 'new'
          else
            render :action => 'edit_batch'
          end
        end
      end
      format.json do
        if errors
          json = if @observations.size == 1 && is_iphone_app_2?
            {:error => @observations.map{|o| o.errors.full_messages}.flatten.uniq.compact.to_sentence}
          else
            {:errors => @observations.map{|o| o.errors.full_messages}}
          end
          render :json => json, :status => :unprocessable_entity
        else
          if @observations.size == 1 && is_iphone_app_2?
            render :json => @observations[0].to_json(
              :viewer => current_user,
              :methods => [:user_login, :iconic_taxon_name],
              :include => {
                :taxon => Taxon.default_json_options,
                :observation_field_values => {}
              }
            )
          else
            render :json => @observations.to_json(:viewer => current_user, :methods => [:user_login, :iconic_taxon_name])
          end
        end
      end
    end
  end

  # PUT /observations/1
  # PUT /observations/1.xml
  def update
    observation_user = current_user
    
    unless params[:admin_action].nil? || !current_user.is_admin?
      observation_user = Observation.find(params[:id]).user
    end
    
    # Handle the case of a single obs
    if params[:observation]
      params[:observations] = [[params[:id], params[:observation]]]
    elsif params[:id] && params[:observations]
      params[:observations] = [[params[:id], params[:observations][0]]]
    end
      
    
    if params[:observations].blank? && params[:observation].blank?
      respond_to do |format|
        format.html do
          flash[:error] = t(:no_observations_submitted)
          redirect_to new_observation_path
        end
        format.json { render :status => :unprocessable_entity, :json => "No observations submitted!" }
      end
      return
    end

    @observations = Observation.all(
      :conditions => [
        "id IN (?) AND user_id = ?", 
        params[:observations].map{|k,v| k},
        observation_user
      ]
    )
    
    # Make sure there's no evil going on
    unique_user_ids = @observations.map(&:user_id).uniq
    more_than_one_observer = unique_user_ids.size > 1
    admin_action = unique_user_ids.first != observation_user.id && current_user.has_role?(:admin)
    if !@observations.blank? && more_than_one_observer && !admin_action
      msg = t(:you_dont_have_permission_to_edit_that_observation)
      respond_to do |format|
        format.html do
          flash[:error] = msg
          redirect_to(@observation || observations_path)
        end
        format.json do
          render :status => :unprocessable_entity, :json => {:error => msg}
        end
      end
      return
    end
    
    # Convert the params to a hash keyed by ID.  Yes, it's weird
    hashed_params = Hash[*params[:observations].to_a.flatten]
    errors = false
    extra_msg = nil
    @observations.each_with_index do |observation,i|
      fieldset_index = observation.id.to_s      
      
      # Update the flickr photos
      # Note: this ignore photos thing is a total hack and should only be
      # included if you are updating observations but aren't including flickr
      # fields, e.g. when removing something from ID please
      if !params[:ignore_photos] && !is_mobile_app?
        # Get photos
        updated_photos = []
        old_photo_ids = observation.photo_ids
        Photo.descendent_classes.each do |klass|
          klass_key = klass.to_s.underscore.pluralize.to_sym
          if params[klass_key] && params[klass_key][fieldset_index]
            updated_photos += retrieve_photos(params[klass_key][fieldset_index], 
              :user => current_user, :photo_class => klass, :sync => true)
          end
        end
        
        if updated_photos.empty?
          observation.photos.clear
        else
          observation.photos = updated_photos
        end
        
        # Destroy old photos.  ObservationPhotos seem to get removed by magic
        doomed_photo_ids = (old_photo_ids - observation.photo_ids).compact
        unless doomed_photo_ids.blank?
          Photo.delay(:priority => INTEGRITY_PRIORITY).destroy_orphans(doomed_photo_ids)
        end

        Photo.descendent_classes.each do |klass|
          klass_key = klass.to_s.underscore.pluralize.to_sym
          next unless params["#{klass_key}_to_sync"] && params["#{klass_key}_to_sync"][fieldset_index]
          next unless photo = observation.photos.compact.last
          photo_o = photo.to_observation
          PHOTO_SYNC_ATTRS.each do |a|
            hashed_params[observation.id.to_s] ||= {}
            if hashed_params[observation.id.to_s][a].blank? && observation.send(a).blank?
              hashed_params[observation.id.to_s][a] = photo_o.send(a)
            end
          end
        end
      end


      # Kind of like :ignore_photos, but :editing_sounds makes it opt-in rather than opt-out
      # If editing sounds and no sound parameters are present, assign to an empty array 
      # This way, sounds will be removed
      if params[:editing_sounds]
        params[:soundcloud_sounds] ||= {fieldset_index => []} 
        params[:soundcloud_sounds][fieldset_index] ||= []
        observation.sounds = Sound.from_observation_params(params, fieldset_index, current_user)
      end
      
      unless observation.update_attributes(hashed_params[observation.id.to_s])
        errors = true
      end

      if !errors && params[:project_id] && !observation.project_observations.where(:project_id => params[:project_id]).exists?
        if @project ||= Project.find(params[:project_id])
          project_observation = ProjectObservation.create(:project => @project, :observation => observation)
          extra_msg = if project_observation.valid?
            "Successfully added to #{@project.title}"
          else
            "Failed to add to #{@project.title}: #{project_observation.errors.full_messages.to_sentence}"
          end
        end
      end
    end

    respond_to do |format|
      if errors
        format.html do
          if @observations.size == 1
            @observation = @observations.first
            render :action => 'edit'
          else
            render :action => 'edit_batch'
          end
        end
        format.xml  { render :xml => @observations.collect(&:errors), :status => :unprocessable_entity }
        format.json do
          render :status => :unprocessable_entity, :json => {
            :error => @observations.map{|o| o.errors.full_messages.to_sentence}.to_sentence,
            :errors => @observations.collect(&:errors)
          }
        end
      elsif @observations.empty?
        msg = if params[:id]
          t(:that_observation_no_longer_exists)
        else
          t(:those_observations_no_longer_exist)
        end
        format.html do
          flash[:error] = msg
          redirect_back_or_default(observations_by_login_path(current_user.login))
        end
        format.json { render :json => {:error => msg}, :status => :gone }
      else
        format.html do
          flash[:notice] = "#{t(:observations_was_successfully_updated)} #{extra_msg}"
          if @observations.size == 1
            redirect_to observation_path(@observations.first)
          else
            redirect_to observations_by_login_path(observation_user.login)
          end
        end
        format.xml  { head :ok }
        format.js { render :json => @observations }
        format.json do
          if @observations.size == 1 && is_iphone_app_2?
            render :json => @observations[0].to_json(
              :methods => [:user_login, :iconic_taxon_name],
              :include => {
                :taxon => Taxon.default_json_options,
                :observation_field_values => {},
                :project_observations => {
                  :include => {
                    :project => {
                      :only => [:id, :title, :description],
                      :methods => [:icon_url]
                    }
                  }
                },
                :observation_photos => {
                  :include => {
                    :photo => {
                      :methods => [:license_code, :attribution],
                      :except => [:original_url, :file_processing, :file_file_size, 
                        :file_content_type, :file_file_name, :mobile, :metadata, :user_id, 
                        :native_realname, :native_photo_id]
                    }
                  }
                },
              })
          else
            render :json => @observations.to_json(:methods => [:user_login, :iconic_taxon_name])
          end
        end
      end
    end
  end
  
  def edit_photos
    @observation_photos = @observation.observation_photos
    if @observation_photos.blank?
      flash[:error] = t(:that_observation_doesnt_have_any_photos)
      return redirect_to edit_observation_path(@observation)
    end
  end
  
  def update_photos
    @observation_photos = ObservationPhoto.all(:conditions => [
      "id IN (?)", params[:observation_photos].map{|k,v| k}])
    @observation_photos.each do |op|
      next unless @observation.observation_photo_ids.include?(op.id)
      op.update_attributes(params[:observation_photos][op.id.to_s])
    end
    
    flash[:notice] = t(:photos_updated)
    redirect_to edit_observation_path(@observation)
  end
  
  # DELETE /observations/1
  # DELETE /observations/1.xml
  def destroy
    @observation.destroy
    respond_to do |format|
      format.html do
        flash[:notice] = t(:observation_was_deleted)
        redirect_to(observations_by_login_path(current_user.login))
      end
      format.xml  { head :ok }
      format.json  { head :ok }
    end
  end

## Custom actions ############################################################

  def curation
    @flags = Flag.paginate(:page => params[:page], 
      :include => :user,
      :conditions => "resolved = false AND flaggable_type = 'Observation'")
  end

  def new_batch
    @step = 1
    @observations = []
    if params[:batch]
      params[:batch][:taxa].each_line do |taxon_name_str|
        next if taxon_name_str.strip.blank?
        latitude = params[:batch][:latitude]
        longitude = params[:batch][:longitude]
        @observations << Observation.new(
          :user => current_user,
          :species_guess => taxon_name_str,
          :taxon => Taxon.single_taxon_for_name(taxon_name_str.strip),
          :place_guess => params[:batch][:place_guess],
          :longitude => longitude,
          :latitude => latitude,
          :map_scale => params[:batch][:map_scale],
          :positional_accuracy => params[:batch][:positional_accuracy],
          :positioning_method => params[:batch][:positioning_method],
          :positioning_device => params[:batch][:positioning_device],
          :location_is_exact => params[:batch][:location_is_exact],
          :observed_on_string => params[:batch][:observed_on_string],
          :time_zone => current_user.time_zone)
      end
      @step = 2
    end
  end

  def new_bulk_csv
    if params[:upload].blank? || params[:upload] && params[:upload][:datafile].blank?
      flash[:error] = "You must select a CSV file to upload."
      return redirect_to :action => "import"
    end

    # Copy to a temp directory
    path = private_page_cache_path(File.join(
      "bulk_observation_files", 
      "#{current_user.login}-#{Time.now.to_i}-#{params[:upload]['datafile'].original_filename}"
    ))
    FileUtils.mkdir_p File.dirname(path), :mode => 0755
    File.open(path, 'wb') { |f| f.write(params[:upload]['datafile'].read) }

    # Send the filename to a background processor
    Delayed::Job.enqueue(BulkObservationFile.new(path, params[:upload][:project_id], params[:upload][:coordinate_system], current_user), 
      :queue => "slow", :priority => USER_PRIORITY)

    # Notify the user that it's getting processed and return them to the upload screen.
    flash[:notice] = 'Observation file has been queued for import.'
    if params[:upload][:project_id].blank?
      redirect_to import_observations_path
    else
      project = Project.find(params[:upload][:project_id].to_i)
      redirect_to(project_path(project))
    end
  end

  # Edit a batch of observations
  def edit_batch
    observation_ids = params[:o].is_a?(String) ? params[:o].split(',') : []
    @observations = Observation.where("id in (?) AND user_id = ?", observation_ids, current_user).
      includes(:quality_metrics, {:observation_photos => :photo}, :taxon)
    @observations.map do |o|
      if o.coordinates_obscured?
        o.latitude = o.private_latitude
        o.longitude = o.private_longitude
      end
      if qm = o.quality_metrics.detect{|qm| qm.user_id == o.user_id}
        o.captive_flag = qm.metric == QualityMetric::WILD && !qm.agree? ? 1 : 0
      else
        o.captive_flag = "unknown"
      end
      o
    end
  end
  
  def delete_batch
    @observations = Observation.all(
      :conditions => [
        "id in (?) AND user_id = ?", params[:o].split(','), current_user])
    @observations.each do |observation|
      observation.destroy if observation.user == current_user
    end
    
    respond_to do |format|
      format.html do
        flash[:notice] = t(:observations_deleted)
        redirect_to observations_by_login_path(current_user.login)
      end
      format.js { render :text => "Observations deleted.", :status => 200 }
    end
  end
  
  # Import observations from external sources
  def import
    if @default_photo_identity ||= @photo_identities.first
      provider_name = if @default_photo_identity.is_a?(ProviderAuthorization)
        @default_photo_identity.provider_name
      else
        @default_photo_identity.class.to_s.underscore.split('_').first
      end
      @default_photo_identity_url = "/#{provider_name.downcase}/photo_fields?context=user"
    end
    @project = Project.find(params[:project_id].to_i) if params[:project_id]
    if logged_in?
      @projects = current_user.project_users.includes(:project).order('lower(projects.title)').collect(&:project)
      @project_templates = {}
      @projects.each do |p|
        @project_templates[p.title] = p.observation_fields.order(:position) if @project && p.id == @project.id
      end
    end
  end
  
  def import_photos
    photos = Photo.descendent_classes.map do |klass|
      retrieve_photos(params[klass.to_s.underscore.pluralize.to_sym], 
        :user => current_user, :photo_class => klass)
    end.flatten.compact
    @observations = photos.map{|p| p.to_observation}
    @observation_photos = ObservationPhoto.includes(:photo, :observation).
      where("photos.native_photo_id IN (?)", photos.map(&:native_photo_id))
    @step = 2
    render :template => 'observations/new_batch'
  rescue Timeout::Error => e
    flash[:error] = t(:sorry_that_photo_provider_isnt_responding)
    Rails.logger.error "[ERROR #{Time.now}] Timeout: #{e}"
    redirect_to :action => "import"
  end

  def import_sounds
    sounds = Sound.from_observation_params(params, 0, current_user)
    @observations = sounds.map{|s| s.to_observation}
    @step = 2
    render :template => 'observations/new_batch'
  end

  def export
puts 'EXPORT' * 100
puts 'EXPORT' * 100
puts 'EXPORT' * 100
puts 'EXPORT' * 100

    search_params, find_options = get_search_params(params)
puts 'EXPORT >> get_search_params'
    search_params = site_search_params(search_params)
puts 'EXPORT >> site_search_params'
    if params[:flow_task_id]
puts 'EXPORT >> params[:flow_task_id]'
      if @flow_task = ObservationsExportFlowTask.find_by_id(params[:flow_task_id])
puts 'EXPORT >> @flow_task = ObservationsExportFlowTask.find_by_id'
        @export_url = FakeView.uri_join(root_url, @flow_task.outputs.first.file.url).to_s
puts 'EXPORT >> @export_url = FakeView.uri_join'
      end
    end
puts '@recent_exports = ObservationsExportFlowTask.where'
    @recent_exports = ObservationsExportFlowTask.where(:user_id => current_user).where("finished_at is not null").order("id desc").limit(10)
puts '@observation_fields = ObservationField.recently_used_by'
    @observation_fields = ObservationField.recently_used_by(current_user).limit(50).sort_by{|of| of.name.downcase}
    respond_to do |format|
      format.html
    end
  end
  
  def add_from_list
    @order = params[:order] || "alphabetical"
    if @list = List.find_by_id(params[:id])
      @cache_key = {:controller => "observations", :action => "add_from_list", :id => @list.id, :order => @order}
      unless fragment_exist?(@cache_key)
        @listed_taxa = @list.listed_taxa.order_by(@order).paginate(:include => {:taxon => [:photos, :taxon_names]}, :page => 1, :per_page => 1000)
        @listed_taxa_alphabetical = @listed_taxa.sort! {|a,b| a.taxon.default_name.name <=> b.taxon.default_name.name}
        @listed_taxa = @listed_taxa_alphabetical if @order == ListedTaxon::ALPHABETICAL_ORDER
        @taxon_ids_by_name = {}
        ancestor_ids = @listed_taxa.map {|lt| lt.taxon_ancestor_ids.to_s.split('/')}.flatten.uniq
        @orders = Taxon.all(:conditions => ["rank = 'order' AND id IN (?)", ancestor_ids], :order => "ancestry")
        @families = Taxon.all(:conditions => ["rank = 'family' AND id IN (?)", ancestor_ids], :order => "ancestry")
      end
    end
    @user_lists = current_user.lists.all(:limit => 100)
    
    respond_to do |format|
      format.html
      format.mobile { render "add_from_list.html.erb" }
      format.js do
        if fragment_exist?(@cache_key)
          render read_fragment(@cache_key)
        else
          render :partial => 'add_from_list.html.erb'
        end
      end
    end
  end
  
  def new_from_list
    @taxa = Taxon.all(:conditions => ["id in (?)", params[:taxa]], :include => :taxon_names)
    if @taxa.blank?
      flash[:error] = t(:no_taxa_selected)
      return redirect_to :action => :add_from_list
    end
    @observations = @taxa.map do |taxon|
      current_user.observations.build(:taxon => taxon, 
        :species_guess => taxon.default_name.name,
        :time_zone => current_user.time_zone)
    end
    @step = 2
    render :new_batch
  end

  # gets observations by user login
  def by_login
    block_if_spam(@selected_user) && return
    search_params, find_options = get_search_params(params)
    search_params.update(:user_id => @selected_user.id,
      :viewer => current_user, 
      :filter_spam => (current_user.blank? || current_user != @selected_user)
    )
    if search_params[:q].blank?
      get_paginated_observations(search_params, find_options)
    else
      search_observations(search_params, find_options)
    end
    
    respond_to do |format|
      format.html do
        @observer_provider_authorizations = @selected_user.provider_authorizations
        if logged_in? && @selected_user.id == current_user.id
          @project_users = current_user.project_users.all(:include => :project, :order => "projects.title")
          if @proj_obs_errors = Rails.cache.read("proj_obs_errors_#{current_user.id}") 
            @project = Project.find_by_id(@proj_obs_errors[:project_id])
            @proj_obs_errors_obs = current_user.observations.all(:conditions => ["id IN (?)", @proj_obs_errors[:errors].keys], :include => [:photos, :taxon])
            Rails.cache.delete("proj_obs_errors_#{current_user.id}")
          end
        end
        
        if (partial = params[:partial]) && PARTIALS.include?(partial)
          return render_observations_partial(partial)
        end
      end
      
      format.mobile
      
      format.json do
        if timestamp = Chronic.parse(params[:updated_since])
          deleted_observation_ids = DeletedObservation.where("user_id = ? AND created_at >= ?", @selected_user, timestamp).
            select(:observation_id).limit(500).map(&:observation_id)
          response.headers['X-Deleted-Observations'] = deleted_observation_ids.join(',')
        end
        render_observations_to_json
      end
      
      format.kml do
        render_observations_to_kml(
          :snippet => "#{CONFIG.site_name} Feed for User: #{@selected_user.login}",
          :description => "#{CONFIG.site_name} Feed for User: #{@selected_user.login}",
          :name => "#{CONFIG.site_name} Feed for User: #{@selected_user.login}"
        )
      end

      format.atom
      format.csv do
        render_observations_to_csv(:show_private => logged_in? && @selected_user.id == current_user.id)
      end
      format.widget do
        if params[:markup_only]=='true'
          render :js => render_to_string(:partial => "widget.html.erb", :locals => {
            :show_user => false, :target => params[:target], :default_image => params[:default_image], :silence => params[:silence]
          })
        else
          render :js => render_to_string(:partial => "widget.js.erb")
        end
      end
      
    end
  end

  def by_login_all
    if @selected_user.id != current_user.id
      flash[:error] = t(:you_dont_have_permission_to_do_that)
      redirect_back_or_default(root_url)
      return
    end
    path_for_csv = private_page_cache_path("observations/#{@selected_user.login}.all.csv")
    delayed_csv(path_for_csv, @selected_user)
  end
  
  # shows observations in need of an ID
  def id_please
    params[:order_by] ||= "created_at"
    params[:order] ||= "desc"
    search_params, find_options = get_search_params(params)
    search_params = site_search_params(search_params)
    find_options.update(
      :per_page => 10,
      :include => [
        :user, 
        {:taxon => [:taxon_names]}, 
        :tags, 
        :photos, 
        {:identifications => [{:taxon => [:taxon_names]}, :user]}, 
        {:comments => [:user]}
      ]
    )
    if search_params[:has]
      search_params[:has] = (search_params[:has].split(',') + ['id_please']).flatten.uniq
    else
      search_params[:has] = 'id_please'
    end
    
    if search_params[:q].blank?
      get_paginated_observations(search_params, find_options)
    else
      search_observations(search_params, find_options)
    end
    
    @top_identifiers = User.order("identifications_count DESC").limit(5)
    if @site && @site.site_only_users
      @top_identifiers = @top_identifiers.where(:site_id => @site)
    end
  end
  
  # Renders observation components as form fields for inclusion in 
  # observation-picking form widgets
  def selector
    search_params, find_options = get_search_params(params)

    @observations = Observation.latest.query(search_params).paginate(find_options)
      
    respond_to do |format|
      format.html { render :layout => false, :partial => 'selector'}
      # format.js
    end
  end
  
  def tile_points
    # Project tile coordinates into lat/lon using a Spherical Merc projection
    merc = SPHERICAL_MERCATOR
    tile_size = 256
    x, y, zoom = params[:x].to_i, params[:y].to_i, params[:zoom].to_i
    swlng, swlat = merc.from_pixel_to_ll([x * tile_size, (y+1) * tile_size], zoom)
    nelng, nelat = merc.from_pixel_to_ll([(x+1) * tile_size, y * tile_size], zoom)
    @observations = Observation.in_bounding_box(swlat, swlng, nelat, nelng).all(
      :select => "id, species_guess, latitude, longitude, user_id, description, private_latitude, private_longitude, time_observed_at",
      :include => [:user, :photos], :limit => 500, :order => "id DESC")
    
    respond_to do |format|
      format.json do
        render :json => @observations.to_json(
          :only => [:id, :species_guess, :latitude, :longitude],
          :include => {
            :user => {:only => :login}
          },
          :methods => [:image_url, :short_description])
      end
    end
  end
  
  def widget
    @project = Project.find_by_id(params[:project_id].to_i) if params[:project_id]
    @place = Place.find_by_id(params[:place_id].to_i) if params[:place_id]
    @taxon = Taxon.find_by_id(params[:taxon_id].to_i) if params[:taxon_id]
    @order_by = params[:order_by] || "observed_on"
    @order = params[:order] || "desc"
    @limit = params[:limit] || 5
    @limit = @limit.to_i
    if %w"logo-small.gif logo-small.png logo-small-white.png none".include?(params[:logo])
      @logo = params[:logo] 
    end
    @logo ||= "logo-small.gif"
    @layout = params[:layout] || "large"
    url_params = {
      :format => "widget", 
      :limit => @limit, 
      :order => @order, 
      :order_by => @order_by,
      :layout => @layout,
    }
    @widget_url = if @place
      observations_url(url_params.merge(:place_id => @place.id))
    elsif @taxon
      observations_url(url_params.merge(:taxon_id => @taxon.id))
    elsif @project
      project_observations_url(@project.id, url_params)
    elsif logged_in?
      observations_by_login_feed_url(current_user.login, url_params)
    end
    if @widget_url
      @widget_url.gsub!('http:', '')
    end
    respond_to do |format|
      format.html
    end
  end
  
  def nearby
    @lat = params[:latitude].to_f
    @lon = params[:longitude].to_f
    if @lat && @lon
      @latrads = @lat * (Math::PI / 180)
      @lonrads = @lon * (Math::PI / 180)
      @observations = Observation.search(:geo => [latrads,lonrads], 
        :page => params[:page],
        :without => {:observed_on => 0},
        :order => "@geodist asc, observed_on desc") rescue []
    end
    
    @observations ||= Observation.latest.paginate(:page => params[:page])
    
    request.format = :mobile
    respond_to do |format|
      format.mobile
    end
  end
  
  def add_nearby
    @observation = current_user.observations.build(:time_zone => current_user.time_zone)
    request.format = :mobile
    respond_to do |format|
      format.mobile
    end
  end
  
  def project
    @project = Project.find(params[:id]) rescue nil
    unless @project
      flash[:error] = t(:that_project_doesnt_exist)
      redirect_to request.env["HTTP_REFERER"] || projects_path
      return
    end
    
    unless request.format == :mobile
      search_params, find_options = get_search_params(params)
      unless @project.parent?
        search_params[:projects] = @project.id
      else
        search_params[:projects] = @project.children.collect(&:id)
      end
      if search_params[:q].blank?
        get_paginated_observations(search_params, find_options)
      else
        search_observations(search_params, find_options)
      end
    end
    
    @project_observations = @project.project_observations.all(
      :conditions => ["observation_id IN (?)", @observations],
      :include => [{:curator_identification => [:taxon, :user]}])
    @project_observations_by_observation_id = @project_observations.index_by(&:observation_id)
    
    @kml_assets = @project.project_assets.select{|pa| pa.asset_file_name =~ /\.km[lz]$/}
    
    respond_to do |format|
      format.html do
        if (partial = params[:partial]) && PARTIALS.include?(partial)
          return render_observations_partial(partial)
        end
      end
      format.json do
        render_observations_to_json
      end
      format.atom do
        @updated_at = Observation.first(:order => 'updated_at DESC').updated_at
        render :action => "index"
      end
      format.csv do
        pagination_headers_for(@observations)
        render :text => ProjectObservation.to_csv(@project_observations, :user => current_user)
      end
      format.kml do
        render_observations_to_kml(
          :snippet => "#{@project.title.html_safe} Observations", 
          :description => "Observations feed for the #{CONFIG.site_name} project '#{@project.title.html_safe}'", 
          :name => "#{@project.title.html_safe} Observations"
        )
      end
      format.widget do
        if params[:markup_only] == 'true'
          render :js => render_to_string(:partial => "widget.html.erb", :locals => {
            :show_user => true, 
            :target => params[:target], 
            :default_image => params[:default_image], 
            :silence => params[:silence]
          })
        else
          render :js => render_to_string(:partial => "widget.js.erb", :locals => {
            :show_user => true
          })
        end
      end
      format.mobile
    end
  end
  
  def project_all
    @project = Project.find(params[:id]) rescue nil
    unless @project
      flash[:error] = t(:that_project_doesnt_exist)
      redirect_to request.env["HTTP_REFERER"] || projects_path
      return
    end
    
    unless @project.curated_by?(current_user)
      flash[:error] = t(:only_project_curators_can_do_that)
      redirect_to request.env["HTTP_REFERER"] || @project
      return
    end

    path_for_csv = private_page_cache_path("observations/project/#{@project.slug}.all.csv")
    delayed_csv(path_for_csv, @project)
  end
  
  def identotron
    @observation = Observation.find_by_id((params[:observation] || params[:observation_id]).to_i)
    @taxon = Taxon.find_by_id(params[:taxon].to_i)
    @q = params[:q] unless params[:q].blank?
    if @observation
      @places = @observation.places.try(:reverse)
      if @observation.taxon && @observation.taxon.species_or_lower?
        @taxon ||= @observation.taxon.genus
      else
        @taxon ||= @observation.taxon
      end
      if @taxon && @places
        @place = @places.reverse.detect {|p| p.taxa.self_and_descendants_of(@taxon).exists?}
      end
    end
    @place ||= (Place.find(params[:place_id]) rescue nil) || @places.try(:last)
    @default_taxa = @taxon ? @taxon.ancestors : Taxon::ICONIC_TAXA
    @taxon ||= Taxon::LIFE
    @default_taxa = [@default_taxa, @taxon].flatten.compact
    @establishment_means = params[:establishment_means] if ListedTaxon::ESTABLISHMENT_MEANS.include?(params[:establishment_means])

    respond_to do |format|
      format.html
    end
  end

  def fields
    @project = Project.find(params[:project_id]) rescue nil
    @observation_fields = if @project
      @project.observation_fields
    elsif params[:observation_fields]
      ObservationField.where("id IN (?)", params[:observation_fields])
    else
      @observation_fields = ObservationField.recently_used_by(current_user).limit(10)
    end
    render :layout => false
  end

  def update_fields
    unless @observation.fields_addable_by?(current_user)
      respond_to do |format|
        msg = t(:you_dont_have_permission_to_do_that)
        format.html do
          flash[:error] = msg
          redirect_back_or_default @observation
        end
        format.json do
          render :status => 401, :json => {:error => msg}
        end
      end
      return
    end

    if params[:observation].blank?
      respond_to do |format|
        msg = t(:you_must_choose_an_observation_field)
        format.html do
          flash[:error] = msg
          redirect_back_or_default @observation
        end
        format.json do
          render :status => :unprocessable_entity, :json => {:error => msg}
        end
      end
      return
    end

    ofv_attrs = params[:observation][:observation_field_values_attributes]
    ofv_attrs.each do |k,v|
      ofv_attrs[k][:updater_user_id] = current_user.id
    end
    o = { :observation_field_values_attributes =>  ofv_attrs}
    respond_to do |format|
      if @observation.update_attributes(o)
        if !params[:project_id].blank? && @observation.user_id == current_user.id && (@project = Project.find(params[:project_id]) rescue nil)
          @project_observation = ProjectObservation.create(:observation => @observation, :project => @project)
        end
        format.html do
          flash[:notice] = I18n.t(:observations_was_successfully_updated)
          if @project_observation && !@project_observation.valid?
            flash[:notice] += I18n.t(:however_there_were_some_issues, :issues => @project_observation.errors.full_messages.to_sentence)
          end
          redirect_to @observation
        end
        format.json do
          render :json => @observation.to_json(
            :viewer => current_user,
            :include => {
              :observation_field_values => {:include => {:observation_field => {:only => [:name]}}}
            }
          )
        end
      else
        msg = "Failed update observation: #{@observation.errors.full_messages.to_sentence}"
        format.html do
          flash[:error] = msg
          redirect_to @observation
        end
        format.json do
          render :status => :unprocessable_entity, :json => {:error => msg}
        end
      end
    end
  end

  def photo
    @observations = []
    @errors = []
    if params[:files].blank?
      respond_to do |format|
        format.json do
          render :status => :unprocessable_entity, :json => {
            :error => "You must include files to convert to observations."
          }
        end
      end
      return
    end
    params[:files].each_with_index do |file, i|
      lp = LocalPhoto.new(:file => file, :user => current_user)
      o = lp.to_observation
      if params[:observations] && obs_params = params[:observations][i]
        obs_params.each do |k,v|
          o.send("#{k}=", v) unless v.blank?
        end
      end
      o.site ||= @site || current_user.site
      if o.save
        @observations << o
      else
        @errors << o.errors
      end
    end
    respond_to do |format|
      format.json do
        unless @errors.blank?
          render :status => :unprocessable_entity, :json => @errors.map{|e| e.full_messages.to_sentence}
          return
        end
        render_observations_to_json(:include => {
          :taxon => {
            :only => [:name, :id, :rank, :rank_level, :is_iconic], 
            :methods => [:default_name, :image_url, :iconic_taxon_name, :conservation_status_name],
            :include => {
              :iconic_taxon => {
                :only => [:id, :name]
              },
              :taxon_names => {
                :only => [:id, :name, :lexicon]
              }
            }
          }
        })
      end
    end
  end

  def stats
    @headless = @footless = true
    search_params, find_options = get_search_params(params)
    stats_adequately_scoped?
  end

  def taxa
    search_params, find_options = get_search_params(params, :skip_order => true, :skip_pagination => true)
    oscope = Observation.query(search_params).scoped
    oscope = oscope.where("1 = 2") unless stats_adequately_scoped?
    sql = if params[:rank] == "leaves" && logged_in? && current_user.is_curator?
      ancestor_ids_sql = <<-SQL
        SELECT DISTINCT regexp_split_to_table(ancestry, '/') AS ancestor_id
        FROM taxa
          JOIN (
            #{oscope.to_sql}
          ) AS observations ON observations.taxon_id = taxa.id
      SQL
      <<-SQL
        SELECT DISTINCT ON (taxa.id) taxa.*
        FROM taxa
          LEFT OUTER JOIN (
            #{ancestor_ids_sql}
          ) AS ancestor_ids ON taxa.id::text = ancestor_ids.ancestor_id
          JOIN (
            #{oscope.to_sql}
          ) AS observations ON observations.taxon_id = taxa.id
        WHERE ancestor_ids.ancestor_id IS NULL
      SQL
    else
      "SELECT DISTINCT ON (taxa.id) taxa.* from taxa INNER JOIN (#{oscope.to_sql}) as o ON o.taxon_id = taxa.id"
    end
    @taxa = Taxon.find_by_sql(sql)
    respond_to do |format|
      format.html do
        @headless = true
        ancestor_ids = @taxa.map{|t| t.ancestor_ids[1..-1]}.flatten.uniq
        ancestors = Taxon.find_all_by_id(ancestor_ids)
        taxa_to_arrange = (ancestors + @taxa).sort_by{|t| "#{t.ancestry}/#{t.id}"}
        @arranged_taxa = Taxon.arrange_nodes(taxa_to_arrange)
        @taxon_names_by_taxon_id = TaxonName.where("taxon_id IN (?)", taxa_to_arrange.map(&:id).uniq).group_by(&:taxon_id)
        render :layout => "bootstrap"
      end
      format.csv do
        render :text => @taxa.to_csv(
          :only => [:id, :name, :rank, :rank_level, :ancestry, :is_active],
          :methods => [:common_name_string, :iconic_taxon_name, 
            :taxonomic_kingdom_name,
            :taxonomic_phylum_name, :taxonomic_class_name,
            :taxonomic_order_name, :taxonomic_family_name,
            :taxonomic_genus_name, :taxonomic_species_name]
        )
      end
      format.json do
        render :json => {
          :taxa => @taxa
        }
      end
    end
  end

  def taxon_stats
    search_params, find_options = get_search_params(params, :skip_order => true, :skip_pagination => true)
    scope = Observation.query(search_params).scoped
    scope = scope.where("1 = 2") unless stats_adequately_scoped?
    species_counts_scope = scope.joins(:taxon)
    unless search_params[:rank] == "leaves" && logged_in? && current_user.is_curator?
      species_counts_scope = species_counts_scope.where("taxa.rank_level <= ?", Taxon::SPECIES_LEVEL)
    end
    species_counts_sql = if search_params[:rank] == "leaves" && logged_in? && current_user.is_curator?
      ancestor_ids_sql = <<-SQL
        SELECT DISTINCT regexp_split_to_table(ancestry, '/') AS ancestor_id
        FROM taxa
          JOIN (
            #{species_counts_scope.to_sql}
          ) AS observations ON observations.taxon_id = taxa.id
      SQL
      <<-SQL
        SELECT
          o.taxon_id,
          count(*) AS count_all
        FROM
          (
            #{species_counts_scope.to_sql}
          ) AS o
            LEFT OUTER JOIN (
              #{ancestor_ids_sql}
            ) AS ancestor_ids ON o.taxon_id::text = ancestor_ids.ancestor_id
        WHERE
          ancestor_ids.ancestor_id IS NULL
        GROUP BY
          o.taxon_id
        ORDER BY count_all desc
        LIMIT 5
      SQL
    else
      <<-SQL
        SELECT
          o.taxon_id,
          count(*) AS count_all
        FROM
          (#{species_counts_scope.to_sql}) AS o
        GROUP BY
          o.taxon_id
        ORDER BY count_all desc
        LIMIT 5
      SQL
    end
    @species_counts = ActiveRecord::Base.connection.execute(species_counts_sql)
    taxon_ids = @species_counts.map{|r| r['taxon_id']}
    @taxa = Taxon.where("id in (?)", @species_counts.map{|r| r['taxon_id']}).includes({:taxon_photos => :photo}, :taxon_names)
    @taxa_by_taxon_id = @taxa.index_by(&:id)
    species_counts_json = @species_counts.map do |row|
      taxon = @taxa_by_taxon_id[row['taxon_id'].to_i]
      taxon.locale = I18n.locale
      {
        :count => row['count_all'],
        :taxon => taxon.as_json(
          :methods => [:default_name, :image_url, :iconic_taxon_name, :conservation_status_name],
          :only => [:id, :name, :rank, :rank_level]
        )
      }
    end
    rank_counts_sql = <<-SQL
      SELECT
        o.rank_name,
        count(*) AS count_all
      FROM
        (#{scope.joins(:taxon).select("DISTINCT ON (taxa.id) taxa.rank AS rank_name").to_sql}) AS o
      GROUP BY o.rank_name
    SQL
    rank_counts = ActiveRecord::Base.connection.execute(rank_counts_sql)
    @rank_counts = {}
    total = 0
    rank_counts.each do |row|
      total += row['count_all'].to_i
      @rank_counts[row['rank_name']] = row['count_all'].to_i
    end
    @rank_counts[:leaves] = species_counts_json.size if search_params[:rank] == "leaves"
    respond_to do |format|
      format.json do
        render :json => {
          :total => rank_counts.map{|r| r['count_all'].to_i}.sum,
          :species_counts => species_counts_json,
          :rank_counts => @rank_counts
        }
      end
    end
  end

  def user_stats
    search_params, find_options = get_search_params(params, :skip_order => true, :skip_pagination => true)
    scope = Observation.query(search_params).scoped
    scope = scope.where("1 = 2") unless stats_adequately_scoped?
    limit = params[:limit].to_i
    limit = 500 if limit > 500 || limit <= 0
    @user_counts = user_obs_counts(scope, limit).to_a
    @user_taxon_counts = user_taxon_counts(scope, limit).to_a
    obs_user_ids = @user_counts.map{|r| r['user_id']}.sort
    tax_user_ids = @user_taxon_counts.map{|r| r['user_id']}.sort

    # the list of top users is probably different for obs and taxa, so grab the leftovers from each
    leftover_obs_user_ids = tax_user_ids - obs_user_ids
    leftover_tax_user_ids = obs_user_ids - tax_user_ids
    @user_counts += user_obs_counts(scope.where("observations.user_id IN (?)", leftover_obs_user_ids)).to_a
    @user_taxon_counts += user_taxon_counts(scope.where("observations.user_id IN (?)", leftover_tax_user_ids)).to_a
    user_ids = (obs_user_ids + tax_user_ids).uniq.sort
    
    @users = User.select("id, login, icon_file_name, icon_updated_at, icon_content_type").where("id in (?)", user_ids)
    @users_by_id = @users.index_by(&:id)
    respond_to do |format|
      format.html do
        @headless = true
        @user_counts_by_user_id = @user_counts.inject({}) {|memo,r| memo[r['user_id'].to_i] = r['count_all'].to_i; memo}
        @user_taxon_counts_by_user_id = @user_taxon_counts.inject({}) {|memo,r| memo[r['user_id'].to_i] = r['count_all'].to_i; memo}
        render :layout => "bootstrap"
      end
      format.json do
        render :json => {
          :total => scope.select("DISTINCT observations.user_id").count,
          :most_observations => @user_counts.map{|row|
            {
              :count => row['count_all'].to_i,
              :user => @users_by_id[row['user_id'].to_i].as_json(
                :only => [:id, :name, :login],
                :methods => [:user_icon_url]
              )
            }
          },
          :most_species => @user_taxon_counts.map{|row|
            {
              :count => row['count_all'].to_i,
              :user => @users_by_id[row['user_id'].to_i].as_json(
                :only => [:id, :name, :login],
                :methods => [:user_icon_url]
              )
            }
          }
        }
      end
    end
  end
  private
  def user_obs_counts(scope, limit = 500)
    user_counts_sql = <<-SQL
        SELECT
          o.user_id,
          count(*) AS count_all
        FROM
          (#{scope.to_sql}) AS o
        GROUP BY
          o.user_id
        ORDER BY count_all desc
        LIMIT #{limit}
    SQL
    ActiveRecord::Base.connection.execute(user_counts_sql)
  end
  def user_taxon_counts(scope, limit = 500)
    unique_taxon_users_scope = scope.
      select("DISTINCT observations.taxon_id, observations.user_id").
      joins(:taxon).
      where("taxa.rank_level <= ?", Taxon::SPECIES_LEVEL).scoped
    user_taxon_counts_sql = <<-SQL
      SELECT
        o.user_id,
        count(*) AS count_all
      FROM
        (#{unique_taxon_users_scope.to_sql}) AS o
      GROUP BY
        o.user_id
      ORDER BY count_all desc
      LIMIT #{limit}
    SQL
    ActiveRecord::Base.connection.execute(user_taxon_counts_sql)
  end
  public

  def accumulation
    params[:order_by] = "observed_on"
    params[:order] = "asc"
    search_params, find_options = get_search_params(params, :skip_pagination => true)
    scope = Observation.query(search_params).scoped
    scope = scope.where("1 = 2") unless stats_adequately_scoped?
    scope = scope.joins(:taxon).
      select("observations.id, observations.user_id, observations.created_at, observations.observed_on, observations.time_observed_at, observations.time_zone, taxa.ancestry, taxon_id").
      where("time_observed_at IS NOT NULL")
    rows = ActiveRecord::Base.connection.execute(scope.to_sql)
    row = rows.first
    @observations = rows.map do |row|
      {
        :id => row['id'].to_i,
        :user_id => row['user_id'].to_i,
        :created_at => DateTime.parse(row['created_at']),
        :observed_on => row['observed_on'] ? Date.parse(row['observed_on']) : nil,
        :time_observed_at => row['time_observed_at'] ? DateTime.parse(row['time_observed_at']).in_time_zone(row['time_zone']) : nil,
        :offset_hours => DateTime.parse(row['time_observed_at']).in_time_zone(row['time_zone']).utc_offset / 60 / 60,
        :ancestry => row['ancestry'],
        :taxon_id => row['taxon_id'] ? row['taxon_id'].to_i : nil
      }
    end
    respond_to do |format|
      format.html do
        @headless = true
        render :layout => "bootstrap"
      end
      format.json do
        render :json => {
          :observations => @observations
        }
      end
    end
  end

  def phylogram
    search_params, find_options = get_search_params(params, :skip_order => true, :skip_pagination => true)
    scope = Observation.query(search_params).scoped
    scope = scope.where("1 = 2") unless stats_adequately_scoped?
    ancestor_ids_sql = <<-SQL
      SELECT DISTINCT regexp_split_to_table(ancestry, '/') AS ancestor_id
      FROM taxa
        JOIN (
          #{scope.to_sql}
        ) AS observations ON observations.taxon_id = taxa.id
    SQL
    sql = <<-SQL
      SELECT taxa.id, name, ancestry
      FROM taxa
        LEFT OUTER JOIN (
          #{ancestor_ids_sql}
        ) AS ancestor_ids ON taxa.id::text = ancestor_ids.ancestor_id
        JOIN (
          #{scope.to_sql}
        ) AS observations ON observations.taxon_id = taxa.id
      WHERE ancestor_ids.ancestor_id IS NULL
    SQL
    @taxa = ActiveRecord::Base.connection.execute(sql)
    respond_to do |format|
      format.html do
        @headless = true
        render :layout => "bootstrap"
      end
      format.json do
        render :json => {
          :taxa => @taxa
        }
      end
    end
  end

  def viewed_updates
    user_viewed_updates
    respond_to do |format|
      format.html { redirect_to @observation }
      format.json { head :no_content }
    end
  end

  def email_export
    unless flow_task = current_user.flow_tasks.find_by_id(params[:id])
      render :status => :unprocessable_entity, :text => "Flow task doesn't exist"
      return
    end
    if flow_task.user_id != current_user.id
      render :status => :unprocessable_entity, :text => "You don't have permission to do that"
      return
    end
    if flow_task.outputs.exists?
      Emailer.observations_export_notification(flow_task).deliver
      render :status => :ok, :text => ""
      return 
    end
    flow_task.options = flow_task.options.merge(:email => true)
    if flow_task.save
      render :status => :ok, :text => ""
    else
      render :status => :unprocessable_entity, :text => flow_task.errors.full_messages.to_sentence
    end
  end

  def community_taxon_summary
    render :layout => false, :partial => "community_taxon_summary"
  end

  def map
    @taxon = Taxon.find_by_id(params[:taxon_id].to_i) if params[:taxon_id]
    @taxon_hash = { }
    if @taxon
      common_name = view_context.common_taxon_name(@taxon).try(:name)
      rank_label = @taxon.rank ? t('ranks.#{ @taxon.rank.downcase }',
        default: @taxon.rank).capitalize : t(:unknown_rank)
      display_name = common_name || (rank_label + " " + @taxon.name)
      @taxon_hash[:display_label] = I18n.t(:observations_of_taxon,
        taxon_name: display_name)
      if @taxon.iconic_taxon
        @taxon_hash[:iconic_taxon_name] = @taxon.iconic_taxon.name
      end
    end
    @about_url = CONFIG.map_about_url ? CONFIG.map_about_url :
      view_context.wiki_page_url('help', anchor: 'mapsymbols')
  end

## Protected / private actions ###############################################
  private

  def user_viewed_updates
    return unless logged_in?
    Update.update_all(
      ["viewed_at = ?", Time.now], 
      ["resource_type = 'Observation' AND resource_id = ? AND subscriber_id = ?", @observation.id, current_user.id]
    )
  end

  def stats_adequately_scoped?
    if params[:d1] && params[:d2]
      d1 = (Date.parse(params[:d1]) rescue Date.today)
      d2 = (Date.parse(params[:d2]) rescue Date.today)
      return false if d2 - d1 > 366
    end
    @stats_adequately_scoped = !(params[:d1].blank? && params[:projects].blank? && params[:place_id].blank? && params[:user_id].blank? && params[:on].blank?)
  end
  
  def retrieve_photos(photo_list = nil, options = {})
    return [] if photo_list.blank?
    photo_list = photo_list.values if photo_list.is_a?(Hash)
    photo_list = [photo_list] unless photo_list.is_a?(Array)
    photo_class = options[:photo_class] || Photo
    
    # simple algorithm,
    # 1. create an array to be passed back to the observation obj
    # 2. check to see if that photo's data has already been stored
    # 3. if yes
    #      retrieve Photo obj and put in array
    #    if no
    #      create Photo obj and put in array
    # 4. return array
    photos = []
    native_photo_ids = photo_list.map{|p| p.to_s}.uniq
    existing = photo_class.includes(:user).where("native_photo_id IN (?)", native_photo_ids).index_by{|p| p.native_photo_id}
    
    photo_list.uniq.each do |photo_id|
      if (photo = existing[photo_id]) || options[:sync]
        api_response = begin
          photo_class.get_api_response(photo_id, :user => current_user)
        rescue JSON::ParserError => e
          Rails.logger.error "[ERROR #{Time.now}] Failed to parse JSON from Flickr: #{e}"
          next
        end
      end
      
      # Sync existing if called for
      if photo
        photo.user ||= options[:user]
        if options[:sync]
          # sync the photo URLs b/c they change when photos become private
          photo.api_response = api_response # set to make sure user validation works
          photo.sync
          photo.save if photo.changed?
        end
      end
      
      # Create a new one if one doesn't already exist
      unless photo
        photo = if photo_class == LocalPhoto
          if photo_id.is_a?(Fixnum) || photo_id.is_a?(String)
            LocalPhoto.find_by_id(photo_id)
          else
            LocalPhoto.new(:file => photo_id, :user => current_user) unless photo_id.blank?
          end
        else
          api_response ||= begin
            photo_class.get_api_response(photo_id, :user => current_user)
          rescue JSON::ParserError => e
            Rails.logger.error "[ERROR #{Time.now}] Failed to parse JSON from Flickr: #{e}"
            nil
          end
          if api_response
            photo_class.new_from_api_response(api_response, :user => current_user, :native_photo_id => photo_id)
          end
        end
      end
      
      if photo.blank?
        Rails.logger.error "[ERROR #{Time.now}] Failed to get photo for photo_class: #{photo_class}, photo_id: #{photo_id}"
      elsif photo.valid?
        photos << photo
      else
        Rails.logger.error "[ERROR #{Time.now}] #{current_user} tried to save an observation with an invalid photo (#{photo}): #{photo.errors.full_messages.to_sentence}"
      end
    end
    photos
  end
  
  # Processes params for observation requests.  Designed for use with 
  # will_paginate and standard observations query API
  def get_search_params(params, options = {})
    # The original params is important for things like pagination, so we 
    # leave it untouched.
    isAdmin = logged_in? and current_user.has_role?(:admin)
    isExporter = logged_in? and current_user.has_role?(:exporter)
    obsLimit = OBS_LIMIT
    obsLimit = @prefs["observations_limits"].to_i || OBS_LIMIT if @prefs

    search_params = params.clone
    
    @swlat = search_params[:swlat] unless search_params[:swlat].blank?
    @swlng = search_params[:swlng] unless search_params[:swlng].blank?
    @nelat = search_params[:nelat] unless search_params[:nelat].blank?
    @nelng = search_params[:nelng] unless search_params[:nelng].blank?
    unless search_params[:place_id].blank?
      @place = begin
        Place.find(search_params[:place_id])
      rescue ActiveRecord::RecordNotFound
        nil
      end
    end
    
    unless search_params[:q].blank?
      search_params[:q] = sanitize_sphinx_query(search_params[:q])
      @q = search_params[:q] unless search_params[:q].blank?
    end
    if Observation::SPHINX_FIELD_NAMES.include?(search_params[:search_on])
      @search_on = search_params[:search_on]
    end
    
    find_options = {
      :include => [:user, {:taxon => [:taxon_names]}, :taggings, {:observation_photos => :photo}],
      :page => search_params[:page]
    }

    unless options[:skip_pagination]
      find_options[:page] = find_options[:page].to_i
      find_options[:page] = 1 if find_options[:page] <= 0
      find_options[:per_page] = @prefs["per_page"] if @prefs
      if !search_params[:per_page].blank?
        find_options.update(:per_page => search_params[:per_page])
      elsif !search_params[:limit].blank?
        find_options.update(:per_page => search_params[:limit])
      end

      if find_options[:per_page] && find_options[:per_page].to_i > 200
        if logged_in? && (isAdmin || isExporter)
          find_options[:per_page] = find_options[:per_page].to_i
        else
          find_options[:per_page] = 200
        end
      end
      find_options[:per_page] = 30 if find_options[:per_page].to_i <= 0

      # Set 20K limit for no logged users
      if logged_in? && isAdmin
        Rails.logger.info 'Set NO limits for admin users'
      # Set observation_limit preference for isExporter users
      elsif logged_in? && isExporter
        if find_options[:page] && find_options[:per_page]
          nitems = find_options[:page].to_i * find_options[:per_page].to_i
          if nitems > obsLimit
            find_options[:limit] = obsLimit
          end
        end
      elsif find_options[:page] && find_options[:per_page]
        nitems = find_options[:page].to_i * find_options[:per_page].to_i
        if nitems > OBS_LIMIT
          find_options[:limit] = OBS_LIMIT
        end
      end
    end

    if search_params[:limit] && search_params[:limit].to_i > 200
      if logged_in? && isAdmin
        find_options[:limit] = search_params[:limit].to_i
      elsif logged_in? && isExporter
        if search_params[:limit].to_i > obsLimit
          find_options[:limit] = obsLimit
        else
          find_options[:limit] = search_params[:limit].to_i
        end
      else
        find_options[:limit] = 200
      end
    end

    unless request && request.format && request.format.html?
      find_options[:include] = [{:taxon => :taxon_names}, {:observation_photos => :photo}, :user]
    end
    
    # iconic_taxa
    if search_params[:iconic_taxa]
      # split a string of names
      if search_params[:iconic_taxa].is_a? String
        search_params[:iconic_taxa] = search_params[:iconic_taxa].split(',')
      end
      
      # resolve taxa entered by name
      search_params[:iconic_taxa] = search_params[:iconic_taxa].map do |it|
        it = it.last if it.is_a?(Array)
        if it.to_i == 0
          Taxon::ICONIC_TAXA_BY_NAME[it]
        else
          Taxon::ICONIC_TAXA_BY_ID[it]
        end
      end
      @iconic_taxa = search_params[:iconic_taxa]
    end
    
    # taxon
    if !search_params[:taxon_id].blank?
      @observations_taxon_id = search_params[:taxon_id] 
      @observations_taxon = Taxon.find_by_id(@observations_taxon_id.to_i)
    elsif !search_params[:taxon_name].blank?
      @observations_taxon_name = search_params[:taxon_name].to_s
      taxon_name_conditions = ["taxon_names.name = ?", @observations_taxon_name]
      includes = nil
      unless @iconic_taxa.blank?
        taxon_name_conditions[0] += " AND taxa.iconic_taxon_id IN (?)"
        taxon_name_conditions << @iconic_taxa
        includes = :taxon
      end
      begin
        @observations_taxon = TaxonName.first(:include => includes, 
          :conditions => taxon_name_conditions).try(:taxon)
      rescue ActiveRecord::StatementInvalid => e
        raise e unless e.message =~ /invalid byte sequence/
        taxon_name_conditions[1] = @observations_taxon_name.encode('UTF-8')
        @observations_taxon = TaxonName.first(:include => includes, 
          :conditions => taxon_name_conditions).try(:taxon)
      end
    end
    search_params[:taxon] = @observations_taxon
    
    if search_params[:has]
      if search_params[:has].is_a?(String)
        search_params[:has] = search_params[:has].split(',')
      end
      @id_please = true if search_params[:has].include?('id_please')
      @with_photos = true if search_params[:has].include?('photos')
      @with_sounds = true if search_params[:has].include?('sounds')
    end
    
    @quality_grade = search_params[:quality_grade]
    @captive = if [true, 'true', 't', 'yes', 'y', 1, '1'].include?(search_params[:captive])
      true
    elsif [false, 'false', 'f', 'no', 'n', 0, '0'].include?(search_params[:captive])
      false
    end
    @identifications = search_params[:identifications]
    @out_of_range = search_params[:out_of_range]

    @license = search_params[:license]
    @licenses = @license.split(' ') if @license.is_a?(String)
    search_params[:license] = @licenses if (@licenses && @licenses.length > 1)

    @photo_license = search_params[:photo_license]
    @photo_license = @photo_license.split(' ') if @photo_license.is_a?(String)
    search_params[:photo_license] = @photo_license if (@photo_license && @photo_license.length > 1)
    
    if options[:skip_order]
      search_params.delete(:order)
      search_params.delete(:order_by)
    else
      search_params[:order_by] = "created_at" if search_params[:order_by] == "observations.id"
      if ORDER_BY_FIELDS.include?(search_params[:order_by].to_s)
        @order_by = search_params[:order_by]
        @order = if %w(asc desc).include?(search_params[:order].to_s.downcase)
          search_params[:order]
        else
          'desc'
        end
      else
        @order_by = "observations.id"
        @order = "desc"
      end
      search_params[:order_by] = "#{@order_by} #{@order}"
    end
    
    # date
    date_pieces = [search_params[:year], search_params[:month], search_params[:day]]
    unless date_pieces.map{|d| d.blank? ? nil : d}.compact.blank?
      search_params[:on] = date_pieces.join('-')
    end
    if search_params[:on].to_s =~ /^\d{4}/
      @observed_on = search_params[:on]
      @observed_on_year, @observed_on_month, @observed_on_day = @observed_on.split('-').map{|d| d.to_i}
    end
    @observed_on_year ||= search_params[:year].to_i unless search_params[:year].blank?
    @observed_on_month ||= search_params[:month].to_i unless search_params[:month].blank?
    @observed_on_day ||= search_params[:day].to_i unless search_params[:day].blank?

    # observation fields
    ofv_params = search_params.select{|k,v| k =~ /^field\:/}
    unless ofv_params.blank?
      @ofv_params = {}
      ofv_params.each do |k,v|
        @ofv_params[k] = {
          :normalized_name => ObservationField.normalize_name(k),
          :value => v
        }
      end
      observation_fields = ObservationField.where("lower(name) IN (?)", @ofv_params.map{|k,v| v[:normalized_name]})
      @ofv_params.each do |k,v|
        v[:observation_field] = observation_fields.detect do |of|
          v[:normalized_name] == ObservationField.normalize_name(of.name)
        end
      end
      @ofv_params.delete_if{|k,v| v[:observation_field].blank?}
      search_params[:ofv_params] = @ofv_params
    end

    @site_uri = params[:site] unless params[:site].blank?

    unless params[:user_id].blank?
      @user = User.find_by_id(params[:user_id])
      @user ||= User.find_by_login(params[:user_id])
    end
    unless params[:projects].blank?
      @projects = Project.find(params[:projects]) rescue []
    end
    if (@pcid = params[:pcid]) && @pcid != 'any'
      @pcid = [true, 'true', 't', 1, '1', 'y', 'yes'].include?(params[:pcid]) ? 'yes' : 'no'
    end

    @geoprivacy = params[:geoprivacy] unless params[:geoprivacy].blank?
    @rank = params[:rank] if Taxon::VISIBLE_RANKS.include?(params[:rank])
    @hrank = params[:hrank] if Taxon::VISIBLE_RANKS.include?(params[:hrank])
    @lrank = params[:lrank] if Taxon::VISIBLE_RANKS.include?(params[:lrank])
    if stats_adequately_scoped?
      @d1 = search_params[:d1]
      @d2 = search_params[:d2]
    else
      search_params[:d1] = nil
      search_params[:d2] = nil
    end
    
    @filters_open = 
      !@q.nil? ||
      !@observations_taxon_id.blank? ||
      !@observations_taxon_name.blank? ||
      !@iconic_taxa.blank? ||
      @id_please == true ||
      !@with_photos.blank? ||
      !@with_sounds.blank? ||
      !@identifications.blank? ||
      !@quality_grade.blank? ||
      !@captive.blank? ||
      !@out_of_range.blank? ||
      !@observed_on.blank? ||
      !@place.blank? ||
      !@ofv_params.blank? ||
      !@pcid.blank? ||
      !@geoprivacy.blank? ||
      !@rank.blank? ||
      !@lrank.blank? ||
      !@hrank.blank?
    @filters_open = search_params[:filters_open] == 'true' if search_params.has_key?(:filters_open)
    
    [search_params, find_options]
  end
  
  # Either make a plain db query and return a WillPaginate collection or make 
  # a Sphinx call if there were query terms specified.
  def get_paginated_observations(search_params, find_options)
    query_scope = Observation.query(search_params).scoped
    if search_params[:filter_spam]
      query_scope = query_scope.not_flagged_as_spam
    end
    if @q
      @observations = if @search_on
        find_options[:conditions] = update_conditions(
          find_options[:conditions], @search_on.to_sym => @q
        )
        query_scope.search(find_options).compact
      else
        query_scope.search(@q, find_options).compact
      end
    end
    if @observations.blank?
      # COUNT( ) OVER( ) works great with smaller result sets, so here
      # we are choosing to use it when there are some decent filters
      # to work with, otherwise we'll use standard paginate which will
      # initiate two separate queries
      if search_params[:place_id] || search_params[:taxon_id] ||
        search_params[:taxon_name] || (search_params[:lat] && search_params[:lng])
        @observations = query_scope.paginate_with_count_over(find_options)
      else
        @observations = query_scope.paginate(find_options)
      end
      unless request.format && request.format.json?
        Observation.preload_associations(@observations,
          [ :sounds,
            :stored_preferences,
            :quality_metrics,
            :projects,
            { :observation_photos => :photo },
            { :user => :stored_preferences },
            { :taxon => :taxon_descriptions },
            { :iconic_taxon => :taxon_descriptions }
          ])
      end
    end
    @observations
  rescue ThinkingSphinx::ConnectionError, Riddle::ResponseError
    Rails.logger.error "[ERROR #{Time.now}] ThinkingSphinx::ConnectionError, hitting the db"
    find_options.delete(:class)
    find_options.delete(:classes)
    find_options.delete(:raise_on_stale)
    @observations = if @q
      Observation.query(search_params).where("species_guess LIKE ?", "%#{@q}%").paginate(find_options)
    else
      Observation.query(search_params).paginate(find_options)
    end
  end
  
  def search_observations(search_params, find_options)
    sphinx_options = find_options.dup
    sphinx_options[:with] = {}
    
    if sphinx_options[:page] && sphinx_options[:page].to_i > 50
      if request.format && request.format.html?
        flash.now[:notice] = t(:heads_up_observation_search_can_only_load)
      end
      sphinx_options[:page] = 50
      find_options[:page] = 50
    end
    
    if search_params[:has]
      # id please
      if search_params[:has].include?('id_please')
        sphinx_options[:with][:has_id_please] = true
      end
      
      # has photos
      if search_params[:has].include?('photos')
        sphinx_options[:with][:has_photos] = true
      end

      # has sounds
      if search_params[:has].include?('sounds')
        sphinx_options[:with][:has_sounds] = true
      end
      
      # geo
      if search_params[:has].include?('geo')
        sphinx_options[:with][:has_geo] = true 
      end
    end

    if Observation::QUALITY_GRADES.include?(search_params[:quality_grade])
      sphinx_options[:conditions] ||= {}
      sphinx_options[:conditions][:quality_grade] = search_params[:quality_grade]
    end
    
    # Bounding box or near point
    if (!search_params[:swlat].blank? && !search_params[:swlng].blank? && 
        !search_params[:nelat].blank? && !search_params[:nelng].blank?)
      swlatrads = search_params[:swlat].to_f * (Math::PI / 180)
      swlngrads = search_params[:swlng].to_f * (Math::PI / 180)
      nelatrads = search_params[:nelat].to_f * (Math::PI / 180)
      nelngrads = search_params[:nelng].to_f * (Math::PI / 180)
      
      # The box straddles the 180th meridian...
      # This is a very stupid solution that just chooses the biggest of the
      # two sides straddling the meridian and queries in that.  Sphinx doesn't
      # seem to support multiple queries on the same attribute, so we can't do
      # the OR clause we do in the equivalent named scope.  Grr.  -kueda
      # 2009-04-10
      if swlngrads > 0 && nelngrads < 0
        lngrange = swlngrads.abs > nelngrads ? swlngrads..Math::PI : -Math::PI..nelngrads
        sphinx_options[:with][:longitude] = lngrange
        # sphinx_options[:with][:longitude] = swlngrads..Math::PI
        # sphinx_options[:with] = {:longitude => -Math::PI..nelngrads}
      else
        sphinx_options[:with][:longitude] = swlngrads..nelngrads
      end
      sphinx_options[:with][:latitude] = swlatrads..nelatrads
    elsif search_params[:lat] && search_params[:lng]
      latrads = search_params[:lat].to_f * (Math::PI / 180)
      lngrads = search_params[:lng].to_f * (Math::PI / 180)
      sphinx_options[:geo] = [latrads, lngrads]
      sphinx_options[:order] = "@geodist asc"
    end
    
    # identifications
    case search_params[:identifications]
    when 'most_agree'
      sphinx_options[:with][:identifications_most_agree] = true
    when 'some_agree'
      sphinx_options[:with][:identifications_some_agree] = true
    when 'most_disagree'
      sphinx_options[:with][:identifications_most_disagree] = true
    end
    
    # Iconic taxa
    unless search_params[:iconic_taxa].blank?
      sphinx_options[:with][:iconic_taxon_id] = \
          search_params[:iconic_taxa].map do |iconic_taxon|
        iconic_taxon.nil? ? nil : iconic_taxon.id
      end
    end
    
    # User ID
    unless search_params[:user_id].blank?
      sphinx_options[:with][:user_id] = search_params[:user_id]
    end
    
    # User login
    unless search_params[:user].blank?
      sphinx_options[:with][:user] = search_params[:user]
    end
    
    # Ordering
    unless search_params[:order_by].blank?
      # observations.id is a more efficient sql clause, but it's not the name of a field in sphinx
      search_params[:order_by].gsub!(/observations\.id/, 'created_at')
      
      if !sphinx_options[:order].blank?
        sphinx_options[:order] += ", #{search_params[:order_by]}"
        sphinx_options[:sort_mode] = :extended
      elsif search_params[:order_by] =~ /\sdesc|asc/i
        sphinx_options[:order] = search_params[:order_by].split.first.to_sym
        sphinx_options[:sort_mode] = search_params[:order_by].split.last.downcase.to_sym
      else
        sphinx_options[:order] = search_params[:order_by].to_sym
      end
    end
    
    unless search_params[:projects].blank?
      sphinx_options[:with][:projects] = if search_params[:projects].is_a?(String) && search_params[:projects].index(',')
        search_params[:projects].split(',')
      else
        [search_params[:projects]].flatten
      end
    end

    unless search_params[:ofv_params].blank?
      ofs = search_params[:ofv_params].map do |k,v|
        v[:observation_field].blank? ? nil : v[:observation_field].id
      end.compact
      sphinx_options[:with][:observation_fields] = ofs unless ofs.blank?
    end
    
    # Sanitize query
    q = sanitize_sphinx_query(@q)
    
    # Field-specific searches
    obs_ids = if @search_on
      sphinx_options[:conditions] ||= {}
      # not sure why sphinx chokes on slashes when searching on attributes...
      sphinx_options[:conditions][@search_on.to_sym] = q.gsub(/\//, '')
      Observation.search_for_ids(find_options.merge(sphinx_options))
    else
      Observation.search_for_ids(q, find_options.merge(sphinx_options))
    end
    @observations = Observation.where("observations.id in (?)", obs_ids).
      order_by(search_params[:order_by]).
      includes(find_options[:include]).scoped

    # lame hacks
    unless search_params[:ofv_params].blank?
      search_params[:ofv_params].each do |k,v|
        next unless of = v[:observation_field]
        next if v[:value].blank?
        v[:observation_field].blank? ? nil : v[:observation_field].id
        @observations = @observations.has_observation_field(of.id, v[:value])
      end
    end    
    @observations = @observations.of(@observations_taxon) if @observations_taxon
    @observations = @observations.in_place(@place) if @place
    @observations = @observations.on(@observed_on) if @observed_on

    if CONFIG.site_only_observations && params[:site].blank?
      @observations = @observations.where("observations.uri LIKE ?", "#{root_url}%")
    end

    @observations = WillPaginate::Collection.create(obs_ids.current_page, obs_ids.per_page, obs_ids.total_entries) do |pager|
      pager.replace(@observations.to_a)
    end

    begin
      @observations.total_entries
    rescue ThinkingSphinx::SphinxError, Riddle::OutOfBoundsError => e
      Rails.logger.error "[ERROR #{Time.now}] Failed sphinx search: #{e}"
      @observations = WillPaginate::Collection.new(1,30, 0)
    end
    @observations
  rescue ThinkingSphinx::ConnectionError, Riddle::ResponseError
    Rails.logger.error "[ERROR #{Time.now}] Failed to connect to sphinx, falling back to db"
    get_paginated_observations(search_params, find_options)
  end
  
  # Refresh lists affected by taxon changes in a batch of new/edited
  # observations.  Note that if you don't set @skip_refresh_lists on the records
  # in @observations before this is called, this won't do anything
  def refresh_lists_for_batch
    return true if @observations.blank?
    taxa = @observations.compact.select(&:skip_refresh_lists).map(&:taxon).uniq.compact
    return true if taxa.blank?
    List.delay(:priority => USER_PRIORITY).refresh_for_user(current_user, :taxa => taxa.map(&:id))
    true
  end
  
  # Tries to create a new observation from the specified Facebook photo ID and
  # update the existing @observation with the new properties, without saving
  def sync_facebook_photo
    fb = current_user.facebook_api
    if fb
      fbp_json = FacebookPhoto.get_api_response(params[:facebook_photo_id], :user => current_user)
      @facebook_photo = FacebookPhoto.new_from_api_response(fbp_json)
    else 
      @facebook_photo = nil
    end
    if @facebook_photo && @facebook_photo.owned_by?(current_user)
      @facebook_observation = @facebook_photo.to_observation
      sync_attrs = [:description] # facebook strips exif metadata so we can't get geo or observed_on :-/
      #, :species_guess, :taxon_id, :observed_on, :observed_on_string, :latitude, :longitude, :place_guess]
      unless params[:facebook_sync_attrs].blank?
        sync_attrs = sync_attrs & params[:facebook_sync_attrs]
      end
      sync_attrs.each do |sync_attr|
        # merge facebook_observation with existing observation
        @observation[sync_attr] ||= @facebook_observation[sync_attr]
      end
      unless @observation.observation_photos.detect {|op| op.photo.native_photo_id == @facebook_photo.native_photo_id}
        @observation.observation_photos.build(:photo => @facebook_photo)
      end
      unless @observation.new_record?
        flash.now[:notice] = t(:preview_of_synced_observation, :url => url_for)
      end
    else
      flash.now[:error] = t(:sorry_we_didnt_find_that_photo)
    end
  end

  # Tries to create a new observation from the specified Flickr photo ID and
  # update the existing @observation with the new properties, without saving
  def sync_flickr_photo
    flickr = get_flickraw
    begin
      fp = flickr.photos.getInfo(:photo_id => params[:flickr_photo_id])
      @flickr_photo = FlickrPhoto.new_from_flickraw(fp, :user => current_user)
    rescue FlickRaw::FailedResponse => e
      Rails.logger.debug "[DEBUG] FlickRaw failed to find photo " +
        "#{params[:flickr_photo_id]}: #{e}\n#{e.backtrace.join("\n")}"
      @flickr_photo = nil
    rescue Timeout::Error => e
      flash.now[:error] = t(:sorry_flickr_isnt_responding_at_the_moment)
      Rails.logger.error "[ERROR #{Time.now}] Timeout: #{e}"
      Airbrake.notify(e, :request => request, :session => session)
      return
    end
    if fp && @flickr_photo && @flickr_photo.valid?
      @flickr_observation = @flickr_photo.to_observation
      sync_attrs = %w(description species_guess taxon_id observed_on 
        observed_on_string latitude longitude place_guess map_scale)
      unless params[:flickr_sync_attrs].blank?
        sync_attrs = sync_attrs & params[:flickr_sync_attrs]
      end
      sync_attrs.each do |sync_attr|
        # merge flickr_observation with existing observation
        val = @flickr_observation.send(sync_attr)
        @observation.send("#{sync_attr}=", val) unless val.blank?
      end
      
      # Note: the following is sort of a hacky alternative to build().  We
      # need to append a new photo object without saving it, but build() won't
      # work here b/c Photo and its descedents use STI, and type is a
      # protected attributes that can't be mass-assigned.
      unless @observation.observation_photos.detect {|op| op.photo.native_photo_id == @flickr_photo.native_photo_id}
        @observation.observation_photos.build(:photo => @flickr_photo)
      end
      
      unless @observation.new_record?
        flash.now[:notice] = t(:preview_of_synced_observation, :url => url_for)
      end
      
      if (@existing_photo = Photo.find_by_native_photo_id(@flickr_photo.native_photo_id)) && 
          (@existing_photo_observation = @existing_photo.observations.first) && @existing_photo_observation.id != @observation.id
        msg = t(:heads_up_this_photo_is_already_associated_with, :url => url_for(@existing_photo_observation))
        flash.now[:notice] = flash.now[:notice].blank? ? msg : "#{flash.now[:notice]}<br/>#{msg}"
      end
    else
      flash.now[:error] = t(:sorry_we_didnt_find_that_photo)
    end
  end
  
  def sync_picasa_photo
    begin
      api_response = PicasaPhoto.get_api_response(params[:picasa_photo_id], :user => current_user)
    rescue Timeout::Error => e
      flash.now[:error] = t(:sorry_picasa_isnt_responding_at_the_moment)
      Rails.logger.error "[ERROR #{Time.now}] Timeout: #{e}"
      Airbrake.notify(e, :request => request, :session => session)
      return
    end
    unless api_response
      Rails.logger.debug "[DEBUG] Failed to find Picasa photo for #{params[:picasa_photo_id]}"
      return
    end
    @picasa_photo = PicasaPhoto.new_from_api_response(api_response, :user => current_user)
    
    if @picasa_photo && @picasa_photo.valid?
      @picasa_observation = @picasa_photo.to_observation
      sync_attrs = PHOTO_SYNC_ATTRS
      unless params[:picasa_sync_attrs].blank?
        sync_attrs = sync_attrs & params[:picasa_sync_attrs]
      end
      sync_attrs.each do |sync_attr|
        @observation.send("#{sync_attr}=", @picasa_observation.send(sync_attr))
      end
      
      unless @observation.observation_photos.detect {|op| op.photo.native_photo_id == @picasa_photo.native_photo_id}
        @observation.observation_photos.build(:photo => @picasa_photo)
      end
      
      flash.now[:notice] = t(:preview_of_synced_observation, :url => url_for)
    else
      flash.now[:error] = t(:sorry_we_didnt_find_that_photo)
    end
  end

  def sync_local_photo
    unless @local_photo = Photo.find_by_id(params[:local_photo_id])
      flash.now[:error] = t(:that_photo_doesnt_exist)
      return
    end
    if @local_photo.metadata.blank?
      flash.now[:error] = t(:sorry_we_dont_have_any_metadata_for_that_photo)
      return
    end
    o = @local_photo.to_observation
    PHOTO_SYNC_ATTRS.each do |sync_attr|
      @observation.send("#{sync_attr}=", o.send(sync_attr)) unless o.send(sync_attr).blank?
    end

    unless @observation.observation_photos.detect {|op| op.photo_id == @local_photo.id}
      @observation.observation_photos.build(:photo => @local_photo)
    end
    
    unless @observation.new_record?
      flash.now[:notice] = t(:preview_of_synced_observation, :url => url_for)
    end
    
    if @existing_photo_observation = @local_photo.observations.where("observations.id != ?", @observation).first
      msg = t(:heads_up_this_photo_is_already_associated_with, :url => url_for(@existing_photo_observation))
      flash.now[:notice] = flash.now[:notice].blank? ? msg : "#{flash.now[:notice]}<br/>#{msg}"
    end
  end
  
  def load_photo_identities
    unless logged_in?
      @photo_identity_urls = []
      @photo_identities = []
      return true
    end
    @photo_identities = Photo.descendent_classes.map do |klass|
      assoc_name = klass.to_s.underscore.split('_').first + "_identity"
      current_user.send(assoc_name) if current_user.respond_to?(assoc_name)
    end.compact
    
    reference_photo = @observation.try(:observation_photos).try(:first).try(:photo)
    reference_photo ||= @observations.try(:first).try(:observation_photos).try(:first).try(:photo)
    reference_photo ||= current_user.photos.order("id ASC").last
    if reference_photo
      assoc_name = reference_photo.class.to_s.underscore.split('_').first + "_identity"
      if current_user.respond_to?(assoc_name)
        @default_photo_identity = current_user.send(assoc_name)
      else
        @default_photo_source = 'local'
      end
    end
    if params[:facebook_photo_id]
      if @default_photo_identity = @photo_identities.detect{|pi| pi.to_s =~ /facebook/i}
        @default_photo_source = 'facebook'
      end
    elsif params[:flickr_photo_id]
      if @default_photo_identity = @photo_identities.detect{|pi| pi.to_s =~ /flickr/i}
        @default_photo_source = 'flickr'
      end
    end
    @default_photo_source ||= if @default_photo_identity && @default_photo_identity.class.name =~ /Identity/
      @default_photo_identity.class.name.underscore.humanize.downcase.split.first
    elsif @default_photo_identity
      "local"
    end
    
    @default_photo_identity_url = nil
    @photo_identity_urls = @photo_identities.map do |identity|
      provider_name = if identity.is_a?(ProviderAuthorization)
        identity.provider_name
      else
        identity.class.to_s.underscore.split('_').first # e.g. FlickrIdentity=>'flickr'
      end
      url = "/#{provider_name.downcase}/photo_fields?context=user"
      @default_photo_identity_url = url if identity == @default_photo_identity
      "{title: '#{provider_name.capitalize}', url: '#{url}'}"
    end
    @photo_sources = @photo_identities.inject({}) do |memo, ident| 
      if ident.respond_to?(:source_options)
        memo[ident.class.name.underscore.humanize.downcase.split.first] = ident.source_options
      else
        memo[:facebook] = {
          :title => 'Facebook', 
          :url => '/facebook/photo_fields', 
          :contexts => [
            ["Your photos", 'user']
          ]
        }
      end
      memo
    end
  end

  def load_sound_identities
    unless logged_in?
      logger.info "not logged in"
      @sound_identities = []
      return true
    end

    @sound_identities = current_user.soundcloud_identity ? [current_user.soundcloud_identity] : []
  end
  
  def load_observation
    render_404 unless @observation = Observation.find_by_id(params[:id] || params[:observation_id],
      :include => [ :quality_metrics,
                    :photos,
                    :identifications,
                    :projects,
                    { :taxon => :taxon_names }
      ]
    )
  end
  
  def require_owner
    unless logged_in? && current_user.id == @observation.user_id
      msg = t(:you_dont_have_permission_to_do_that)
      respond_to do |format|
        format.html do
          flash[:error] = msg
          return redirect_to @observation
        end
        format.json do
          return render :json => {:error => msg}
        end
      end
    end
  end
  
  def render_observations_to_json(options = {})
    if (partial = params[:partial]) && PARTIALS.include?(partial)
Rails.logger.info 'R' * 100
Rails.logger.info 'R' * 100
Rails.logger.info options.inspect
Rails.logger.info 'R' * 100
Rails.logger.info 'R' * 100
      Observation.preload_associations(@observations, [
        :stored_preferences,
        { :taxon => :taxon_descriptions },
        { :iconic_taxon => :taxon_descriptions } ])
      data = @observations.map do |observation|
        item = {
          :instance => observation,
          :extra => {
            :taxon => observation.taxon,
            :iconic_taxon => observation.iconic_taxon,
            :user => {:login => observation.user.login}
          }
        }
        item[:html] = view_context.render_in_format(:html, :partial => partial, :object => observation)
        item
      end
      render :json => data
    else
      opts = options
      opts[:methods] ||= []
      opts[:methods] += [:short_description, :user_login, :iconic_taxon_name, :tag_list]
      opts[:methods].uniq!
      opts[:include] ||= {}
      opts[:include][:taxon] ||= {
        :only => [:id, :name, :rank, :ancestry],
        :methods => [:common_name]
      }
      opts[:include][:iconic_taxon] ||= {:only => [:id, :name, :rank, :rank_level, :ancestry]}
      opts[:include][:user] ||= {:only => :login}
      opts[:include][:photos] ||= {
        :methods => [:license_code, :attribution],
        :except => [:original_url, :file_processing, :file_file_size, 
          :file_content_type, :file_file_name, :mobile, :metadata]
      }
      extra = params[:extra].to_s.split(',')
      if extra.include?('projects')
        opts[:include][:project_observations] ||= {
          :include => {:project => {:only => [:id, :title]}},
          :except => [:tracking_code]
        }
      end
      if extra.include?('observation_photos')
        opts[:include][:observation_photos] ||= {
          :include => {:photo => {:except => [:metadata]}}
        }
      end
      if @ofv_params || extra.include?('fields')
        opts[:include][:observation_field_values] ||= {
          :except => [:observation_field_id],
          :include => {
            :observation_field => {
              :only => [:id, :datatype, :name, :allowed_values]
            }
          }
        }
      end
      pagination_headers_for(@observations)
      opts[:viewer] = current_user
      if @observations.respond_to?(:scoped)
        Observation.preload_associations(@observations, [ {:observation_photos => { :photo => :user } }, :photos, :iconic_taxon ])
      end
Rails.logger.info '#'* 100
Rails.logger.info '#'* 100
Rails.logger.info @observations.count
Rails.logger.info opts.inspect
Rails.logger.info '#'* 100
Rails.logger.info '#'* 100
      render :json => @observations.to_json(opts)
    end
  end
  
  def render_observations_to_csv(options = {})
    first = %w(scientific_name datetime description place_guess latitude longitude tag_list common_name url image_url user_login)
    only = (first + Observation::CSV_COLUMNS).uniq
    except = %w(map_scale timeframe iconic_taxon_id delta geom user_agent cached_tag_list)
    unless options[:show_private] == true
      except += %w(private_latitude private_longitude private_positional_accuracy)
    end
    only = only - except
    unless @ofv_params.blank?
      only += @ofv_params.map{|k,v| "field:#{v[:normalized_name]}"}
      if @observations.respond_to?(:scoped)
        Observation.preload_associations(@observations, { :observation_field_values => :observation_field })
      end
    end
    Observation.preload_associations(@observations, :tags) if @observations.respond_to?(:scoped)
    pagination_headers_for(@observations)
    render :text => @observations.to_csv(:only => only.map{|c| c.to_sym})
  end
  
  def render_observations_to_kml(options = {})
    @net_hash = options
    if params[:kml_type] == "network_link"
      kml_query = request.query_parameters.reject{|k,v| REJECTED_KML_FEED_PARAMS.include?(k.to_s) || k.to_s == "kml_type"}.to_query
      kml_href = "#{request.base_url}#{request.path}"
      kml_href += "?#{kml_query}" unless kml_query.blank?
      @net_hash = {
        :id => "AllObs", 
        :link_id =>"AllObs", 
        :snippet => "#{CONFIG.site_name} Feed for Everyone", 
        :description => "#{CONFIG.site_name} Feed for Everyone", 
        :name => "#{CONFIG.site_name} Feed for Everyone", 
        :href => kml_href
      }
      render :layout => false, :action => 'network_link'
      return
    end
    render :layout => false, :action => "index"
  end
  
  # create project observations if a project was specified and project allows 
  # auto-joining
  def create_project_observations
    return unless params[:project_id]
    @project = Project.find_by_id(params[:project_id])
    @project ||= Project.find(params[:project_id]) rescue nil
    return unless @project
    @project_user = current_user.project_users.find_or_create_by_project_id(@project.id)
    return unless @project_user && @project_user.valid?
    tracking_code = params[:tracking_code] if @project.tracking_code_allowed?(params[:tracking_code])
    errors = []
    @observations.each do |observation|
      next if observation.new_record?
      po = @project.project_observations.build(:observation => observation, :tracking_code => tracking_code)
      unless po.save
        errors = (errors + po.errors.full_messages).uniq
      end
    end
     
    if !errors.blank?
      if request.format.html?
        flash[:error] = t(:your_observations_couldnt_be_added_to_that_project, :errors => errors.to_sentence)
      else
        Rails.logger.error "[ERROR #{Time.now}] Failed to add #{@observations.size} obs to #{@project}: #{errors.to_sentence}"
      end
    end
  end
  
  def update_user_account
    current_user.update_attributes(params[:user]) unless params[:user].blank?
  end
  
  def render_observations_partial(partial)
    if @observations.empty?
      render(:text => '')
    else
      render(:partial => partial, :collection => @observations, :layout => false)
    end
  end

  def load_prefs
    @prefs = current_preferences
    if request.format && request.format.html?
      @view = params[:view] || current_user.try(:preferred_observations_view) || 'map'
    end
  end

  def site_search_params(search_params = {})
    if CONFIG.site_only_observations && params[:site].blank?
      search_params[:site] ||= FakeView.root_url
    end
    if (site_bounds = CONFIG.bounds) && params[:swlat].blank? && params[:place_id].blank? & params[:bbox].blank?
      search_params[:nelat] ||= site_bounds['nelat']
      search_params[:nelng] ||= site_bounds['nelng']
      search_params[:swlat] ||= site_bounds['swlat']
      search_params[:swlng] ||= site_bounds['swlng']
      @nelat ||= site_bounds['nelat']
      @nelng ||= site_bounds['nelng']
      @swlat ||= site_bounds['swlat']
      @swlng ||= site_bounds['swlng']
    end
    search_params
  end

  def delayed_csv(path_for_csv, parent, options = {})
    path_for_csv_no_ext = path_for_csv.gsub(/\.csv\z/, '')
    if parent.observations.count < 50
      Observation.generate_csv_for(parent, :path => path_for_csv)
      render :file => path_for_csv_no_ext, :formats => [:csv]
    else
      cache_key = Observation.generate_csv_for_cache_key(parent)
      job_id = Rails.cache.read(cache_key)
      job = Delayed::Job.find_by_id(job_id)
      if job
        # Still working
      elsif File.exists? path_for_csv
        render :file => path_for_csv_no_ext, :formats => [:csv]
        return
      else
        # no job id, no job, let's get this party started
        Rails.cache.delete(cache_key)
        job = Observation.delay(:priority => NOTIFICATION_PRIORITY).generate_csv_for(parent, :path => path_for_csv, :user => current_user)
        Rails.cache.write(cache_key, job.id, :expires_in => 1.hour)
      end
      prevent_caching
      render :status => :accepted, :text => "This file takes a little while to generate. It should be ready shortly at #{request.url}"
    end
  end
end
