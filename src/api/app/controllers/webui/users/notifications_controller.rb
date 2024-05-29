class Webui::Users::NotificationsController < Webui::WebuiController
  include Webui::NotificationsFilter

  ALLOWED_FILTERS = %w[all comments requests incoming_requests outgoing_requests relationships_created relationships_deleted build_failures
                       reports reviews workflow_runs appealed_decisions].freeze
  ALLOWED_STATES = %w[unread read].freeze

  before_action :require_login
  before_action :set_filter_type, :set_filter_state, :set_filter_project, :set_filter_group
  before_action :set_notifications
  before_action :set_notifications_to_be_updated, only: [:update]
  before_action :set_show_read_all_button
  before_action :set_selected_filter
  before_action :paginate_notifications

  def index
    @current_user = User.session
  end

  def update
    # rubocop:disable Rails/SkipsModelValidations
    if @filter_state.include?('unread')
      @read_count = Notification.where(id: @undelivered_notification_ids).update_all('delivered = !delivered')
      @unread_count = 0
    else
      @unread_count = Notification.where(id: @delivered_notification_ids).update_all('delivered = !delivered')
      @read_count = 0
    end
    # rubocop:enable Rails/SkipsModelValidations

    respond_to do |format|
      format.html { redirect_to my_notifications_path }
      format.js do
        render partial: 'update', locals: {
          notifications: @notifications,
          all_filtered_notifications: @all_filtered_notifications,
          selected_filter: @selected_filter,
          show_read_all_button: @show_read_all_button,
          user: User.session
        }
      end
      send_notifications_information_rabbitmq(@read_count, @unread_count)
    end
  end

  private

  def set_filter_type
    @filter_type = Array(params[:kind].presence || 'all') # in case just one value, we want an array anyway
    raise FilterNotSupportedError unless (@filter_type - ALLOWED_FILTERS).empty?

    @filter_type
  end

  def set_filter_state
    @filter_state = Array(params[:state].presence || 'unread') # in case just one value, we want an array anyway
    raise FilterNotSupportedError unless (@filter_state - ALLOWED_STATES).empty?
  end

  def set_filter_project
    @filter_project = params[:project] || []
  end

  def set_filter_group
    @filter_group = params[:group] || []
  end

  def set_notifications
    @notifications = User.session!.notifications.for_web.includes(notifiable: [{ commentable: [{ comments: :user }, :project, :bs_request_actions] }, :bs_request_actions, :reviews])
    @notifications = filter_notifications_by_project(@notifications, @filter_project)
    @notifications = filter_notifications_by_group(@notifications, @filter_group)
    @notifications = filter_notifications_by_state(@notifications, @filter_state)
    @notifications = filter_notifications_by_type(@notifications, @filter_type)
  end

  def set_notifications_to_be_updated
    if params[:notification_ids]
      @undelivered_notification_ids = @notifications.where(id: params[:notification_ids]).where(delivered: false).map(&:id)
      @delivered_notification_ids = @notifications.where(id: params[:notification_ids]).where(delivered: true).map(&:id)
    elsif params[:update_all]
      @undelivered_notification_ids = @notifications.where(delivered: false).map(&:id)
      @delivered_notification_ids = @notifications.where(delivered: true).map(&:id)
    else
      @undelivered_notification_ids = []
      @delivered_notification_ids = []
    end
  end

  def set_show_read_all_button
    @show_read_all_button = @notifications.count > Notification::MAX_PER_PAGE
  end

  def set_selected_filter
    @selected_filter = { kind: @filter_type, state: @filter_state, project: @filter_project, group: @filter_group }
  end

  def show_more(notifications)
    total = notifications.size
    flash.now[:info] = "You have too many notifications. Displaying a maximum of #{Notification::MAX_PER_PAGE} notifications per page." if total > Notification::MAX_PER_PAGE
    notifications.page(params[:page]).per([total, Notification::MAX_PER_PAGE].min)
  end

  def send_notifications_information_rabbitmq(read_count, unread_count)
    RabbitmqBus.send_to_bus('metrics', "notification,action=read value=#{read_count}") if read_count.positive?
    RabbitmqBus.send_to_bus('metrics', "notification,action=unread value=#{unread_count}") if unread_count.positive?
  end

  def paginate_notifications
    @all_filtered_notifications = @notifications
    @notifications = params[:show_more] ? show_more(@notifications) : @notifications.page(params[:page])
    params[:page] = @notifications.total_pages if @notifications.out_of_range?
  end
end
