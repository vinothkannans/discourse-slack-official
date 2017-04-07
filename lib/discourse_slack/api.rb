module DiscourseSlack
  class API

    BASE_URL = "https://slack.com/api/"

    def self.http
      @http ||= begin
        http = Net::HTTP.new("slack.com" , 443)
        http.use_ssl = true

        http
      end
    end

    def self.get_request(uri)
      response = http.request(Net::HTTP::Get.new(uri))

      return JSON(response.body) if response && response.code == "200"

      { "error": I18n.t('slack.errors.invalid_response') }
    end

    def self.api_uri(method, params = {})
      params.merge!(token_param)
      URI("#{BASE_URL}#{method}?#{params.to_query}")
    end

    def self.channels
      return [] if SiteSetting.slack_access_token.empty?

      @channels = Rails.cache.fetch("slack_channels", expires_in: 15.minutes) do
        result = get_request(api_uri("channels.list"))
        result["error"].present? ? [] : result
      end

      Rails.cache.delete("slack_channels") if @channels.blank?

      @channels
    end

    def self.users
      return [] if SiteSetting.slack_access_token.empty?

      @users = Rails.cache.fetch("slack_users", expires_in: 12.hours) do
        users = Hash.new
        result = get_request(api_uri("users.list"))
        members = result["error"].present? ? [] : result["members"]
        members.each do |member|
          users[member["id"]] = member
        end
        users
      end

      Rails.cache.delete("slack_users") if @users.blank?

      @users
    end

    def self.messages(channel, count)
      return { "error": I18n.t('slack.errors.access_token_is_empty') } if SiteSetting.slack_access_token.empty?

      get_request(api_uri("channels.history", channel: channel, count: count ))
    end

    private

      def self.token_param
        { token: SiteSetting.slack_access_token }
      end

  end
end
