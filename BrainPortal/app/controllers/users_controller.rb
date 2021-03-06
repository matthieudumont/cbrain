
#
# CBRAIN Project
#
# Copyright (C) 2008-2012
# The Royal Institution for the Advancement of Learning
# McGill University
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

require 'ipaddr'

#RESTful controller for the User resource.
class UsersController < ApplicationController

  Revision_info=CbrainFileRevision[__FILE__] #:nodoc:

  api_available :only => [ :index, :create, :show, :destroy , :update]

  before_filter :login_required,        :except => [:request_password, :send_password]
  before_filter :manager_role_required, :except => [:show, :edit, :update, :request_password, :send_password, :change_password]

  API_HIDDEN_ATTRIBUTES = [ :salt, :crypted_password ]

  def index #:nodoc:
    @scope = scope_from_session('users')
    scope_default_order(@scope, 'full_name')

    params[:name_like].strip! if params[:name_like]
    scope_filter_from_params(@scope, :name_like, {
      :attribute => 'full_name',
      :operator  => 'match'
    })

    @base_scope = current_user.available_users.includes(:groups, :site)
    @users = @view_scope = @scope.apply(@base_scope)

    @scope.pagination ||= Scope::Pagination.from_hash({ :per_page => 50 })
    @users = @scope.pagination.apply(@view_scope) if
      [:html, :js].include?(request.format.to_sym)

    # Precompute file, task and locked/unlocked counts.
    @users_file_counts    = Userfile.where(:user_id => @view_scope).group(:user_id).count
    @users_task_counts    = CbrainTask.real_tasks.where(:user_id => @view_scope).group(:user_id).count
    @locked_users_count   = @view_scope.where(:account_locked => true).count
    @unlocked_users_count = @view_scope.count - @locked_users_count

    scope_to_session(@scope)

    respond_to do |format|
      format.html # index.html.erb
      format.js
      format.xml  do
        @users.each { |u| u.hide_attributes(API_HIDDEN_ATTRIBUTES) }
        render :xml  => @users
      end
      format.json do
        @users.each { |u| u.hide_attributes(API_HIDDEN_ATTRIBUTES) }
        render :json => @users
      end
    end
  end

  # GET /user/1
  # GET /user/1.xml
  def show #:nodoc:
    @user = User.find(params[:id], :include => :groups)

    cb_error "You don't have permission to view this page.", :redirect  => start_page_path unless edit_permission?(@user)

    @default_data_provider  = DataProvider.find_by_id(@user.meta["pref_data_provider_id"])
    @default_bourreau       = Bourreau.find_by_id(@user.meta["pref_bourreau_id"])
    @log                    = @user.getlog()

    respond_to do |format|
      format.html # show.html.erb
      format.xml  do
        @user.hide_attributes(API_HIDDEN_ATTRIBUTES)
        render :xml  => @user
      end
      format.json do
        @user.hide_attributes(API_HIDDEN_ATTRIBUTES)
        render :json => @user
      end
    end
  end

  def new #:nodoc:
    @user        = User.new
    @random_pass = User.random_string

    # Pre-load attributes based on signup ID given in path.
    if params[:signup_id].present?
      if signup = Signup.where(:id => params[:signup_id]).first # assignment, not comparison!
        @user  = signup.to_user
        flash.now[:notice] = "Fields have been filled from a signup request."
      end
    end
  end

  def create #:nodoc:
    cookies.delete :auth_token
    # protects against session fixation attacks, wreaks havoc with
    # request forgery protection.
    # uncomment at your own risk
    # reset_session
    params[:user] ||= {}

    no_password_reset_needed = params[:no_password_reset_needed] == "1"

    if current_user.has_role? :site_manager
      if params[:user][:type] == 'SiteManager'
        params[:user][:type] = 'SiteManager'
      else
        params[:user][:type] = 'NormalUser'
      end
    end

    @user = User.new

    @user.make_all_accessible! if current_user.has_role?(:admin_user)
    if current_user.has_role?(:site_manager)
      @user.make_accessible!(:login, :type, :group_ids, :account_locked)
      @user.site = current_user.site
    end

    @user.attributes = params[:user]

    @user = @user.class_update

    @user.password_reset = no_password_reset_needed ? false : true

    if @user.save
      flash[:notice] = "User successfully created."

      # Find signup record matching login name, and log creation and transfer some info.
      if signup = Signup.where(:login => @user.login, :approved_at => nil, :approved_by => nil).first
        current_user.addlog("Approved [[signup request][#{signup_path(signup)}]] for user '#{@user.login}'")
        @user.addlog("Account created after signup request approved by '#{current_user.login}'")
        signup.add_extra_info_for_user(@user)
        signup.approved_by = current_user.login
        signup.approved_at = Time.now
        signup.save
      else # account was not created from a signup request? Still log some info.
        current_user.addlog_context(self,"Created account for user '#{@user.login}'")
        @user.addlog_context(self,"Account created by '#{current_user.login}'")
      end

      if @user.email.blank? || @user.email =~ /example/i || @user.email !~ /@/
        flash[:notice] += "Since this user has no proper email address, no welcome email was sent."
      else
        if send_welcome_email(@user, params[:user][:password], no_password_reset_needed)
          flash[:notice] += "\nA welcome email is being sent to '#{@user.email}'."
        else
          flash[:error] = "Could not send email to '#{@user.email}' informing them that their account was created."
        end
      end
      respond_to do |format|
        format.html { redirect_to :action => :index, :format => :html }
        format.xml  { render :xml  => @user }
        format.json { render :json => @user }
      end
    else
      respond_to do |format|
        format.html { render :action => :new }
        format.xml  { render :xml  => @user.errors, :status => :unprocessable_entity }
        format.json { render :json => @user.errors, :status => :unprocessable_entity }
      end
    end
  end

  def change_password #:nodoc:
    @user = User.find(params[:id])
    cb_error "You don't have permission to view this page.", :redirect => start_page_path unless edit_permission?(@user)
  end

  # PUT /users/1
  # PUT /users/1.xml
  def update #:nodoc:
    @user = User.find(params[:id], :include => :groups)
    params[:user] ||= {}
    cb_error "You don't have permission to view this page.", :redirect => start_page_path unless edit_permission?(@user)

    if params[:user][:group_ids]
      system_group_scope = SystemGroup.scoped
      params[:user][:group_ids]  |= system_group_scope.joins(:users).where( "users.id" => @user.id ).raw_first_column("groups.id").map(&:to_s)
      unless current_user.has_role?(:admin_user)
        params[:user][:group_ids]  |= WorkGroup.where(invisible: true).raw_first_column("groups.id").map(&:to_s)
      end
    end

    if params[:user][:password].present?
      if current_user.id == @user.id
        @user.password_reset = false
      else
        @user.password_reset = params[:force_password_reset] != '0'
      end
    else
      params[:user].delete(:password)
      params[:user].delete(:password_confirmation)
    end

    if params[:user].has_key?(:time_zone) && (params[:user][:time_zone].blank? || !ActiveSupport::TimeZone[params[:user][:time_zone]])
      params[:user][:time_zone] = nil # change "" to nil
    end

    # IP whitelist
    params[:meta][:ip_whitelist].split(',').each do |ip|
      IPAddr.new(ip.strip) rescue cb_error "Invalid whitelist IP address: #{ip}"
    end if
      params[:meta] && params[:meta][:ip_whitelist]

    # For logging
    original_group_ids = @user.group_ids
    original_ap_ids    = @user.access_profile_ids


    @user.make_all_accessible! if current_user.has_role?(:admin_user)
    if current_user.has_role? :site_manager
      @user.make_accessible!(:group_ids, :type, :account_locked)
      if params[:user][:type] == 'SiteManager'
        params[:user][:type] = 'SiteManager'
      else
        params[:user][:type] = 'NormalUser'
      end
      @user.site = current_user.site
    end

    @user.attributes = params[:user]

    remove_ap_ids    = original_ap_ids - @user.access_profile_ids
    remove_group_ids = remove_ap_ids.present? ? AccessProfile.find(remove_ap_ids).map(&:group_ids).flatten.uniq : []

    @user.apply_access_profiles(remove_group_ids: remove_group_ids)

    @user = @user.class_update

    respond_to do |format|
      if @user.save_with_logging(current_user, %w( full_name login email role city country account_locked ) )
        @user.reload
        @user.addlog_object_list_updated("Groups", Group, original_group_ids, @user.group_ids, current_user)
        @user.addlog_object_list_updated("Access Profiles", AccessProfile, original_ap_ids, @user.access_profile_ids, current_user)
        add_meta_data_from_form(@user, [:pref_bourreau_id, :pref_data_provider_id, :ip_whitelist])
        flash[:notice] = "User #{@user.login} was successfully updated."
        format.html { redirect_to :action => :show }
        format.xml { head :ok }
        format.json  { render :json => @user }
      else
        @user.reload
        format.html do
          if params[:user][:password]
            render action: "change_password"
          else
            render action: "show"
          end
        end
        format.xml  { render :xml => @user.errors, :status => :unprocessable_entity }
        format.json { render :json => @user.errors, :status => :unprocessable_entity }
      end
    end
  end

  def destroy #:nodoc:
    if current_user.has_role? :admin_user
      @user = User.find(params[:id])
    elsif current_user.has_role? :site_manager
      @user = current_user.site.users.find(params[:id])
    end

    @user.destroy

    flash[:notice] = "User '#{@user.login}' destroyed"

    respond_to do |format|
      format.html { redirect_to :action => :index }
      format.js   { redirect_to :action => :index, :format => :js}
      format.xml  { head :ok }
      format.json { head :ok }
    end
  rescue ActiveRecord::DeleteRestrictionError => e
    flash[:error]  = "User not destroyed: #{e.message}"

    respond_to do |format|
      format.html { redirect_to :action => :index }
      format.js   { redirect_to :action => :index, :format => :js}
      format.xml  { head :conflict }
      format.json { head :conflict}
    end
  end

  def switch #:nodoc:
    if current_user.has_role? :admin_user
      @user = User.find(params[:id])
    elsif current_user.has_role? :site_manager
      @user = current_user.site.users.find(params[:id])
    end

    myportal = RemoteResource.current_resource
    myportal.addlog("Admin user '#{current_user.login}' switching to user '#{@user.login}'")
    current_user.addlog("Switching to user '#{@user.login}'")
    @user.addlog("Switched from user '#{current_user.login}'")
    current_session.clear
    self.current_user = @user
    current_session[:user_id] = @user.id

    redirect_to start_page_path
  end

  def request_password #:nodoc:
  end

  def send_password #:nodoc:
    @user = User.where( :login  => params[:login], :email  => params[:email] ).first

    if @user
      if @user.account_locked?
        contact = RemoteResource.current_resource.support_email.presence || User.admin.email.presence || "the support staff"
        flash[:error] = "This account is locked, please write to #{contact} to get this account unlocked."
        respond_to do |format|
          format.html { redirect_to :action  => :request_password }
          format.xml  { render :nothing => true, :status  => 401 }
        end
        return
      end
      @user.password_reset = true
      @user.set_random_password
      if @user.save
        if send_forgot_password_email(@user)
          flash[:notice] = "#{@user.full_name}, your new password has been sent to you via e-mail. You should receive it shortly."
          flash[:notice] += "\nIf you do not receive your new password within 24hrs, please contact your admin."
        else
          flash[:error] = "Could not send an email with the reset password!\nPlease contact your admin."
        end
        redirect_to login_path
      else
        flash[:error] = "Unable to reset password.\nPlease contact your admin."
        redirect_to :action  => :request_password
      end
    else
      flash[:error] = "Unable to find user with login #{params[:login]} and email #{params[:email]}.\nPlease contact your admin."
      redirect_to :action  => :request_password
    end
  end

  private

  # Sends email and returns true/false if it succeeds/fails
  def send_welcome_email(user, password, no_password_reset_needed) #:nodoc:
    CbrainMailer.registration_confirmation(user,password,no_password_reset_needed).deliver
    return true
  rescue => ex
    Rails.logger.error ex.to_s
    return false
  end

  # Sends email and returns true/false if it succeeds/fails
  def send_forgot_password_email(user) #:nodoc:
    CbrainMailer.forgotten_password(user).deliver
    return true
  rescue => ex
    Rails.logger.error ex.to_s
    return false
  end



end
