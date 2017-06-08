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

      response.body
    end

    def self.api_uri(method, params = {})
      params.merge!(token_param)
      URI("#{BASE_URL}#{method}?#{params.to_query}")
    end

    def self.sync_channels
      return if SiteSetting.slack_access_token.empty?

      result = get_request(api_uri("channels.list"))
      return unless result["channels"].present?

      channels = Hash.new
      result["channels"].each do |c|
        channels[c["id"]] = c
      end

      PluginStore.set(DiscourseSlack::PLUGIN_NAME, "slack_channels", channels)
    end

    def self.sync_users
      return if SiteSetting.slack_access_token.empty?

      result = get_request(api_uri("users.list"))
      return unless result["members"].present?

      users = Hash.new
      result["members"].each do |m|
        users[m["id"]] = m
      end

      PluginStore.set(DiscourseSlack::PLUGIN_NAME, "slack_users", users)
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
