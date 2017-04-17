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

    def self.history_url(params = {})
      params.merge!(token_param)
      "#{BASE_URL}channels.history?#{params.to_query}"
    end

    def self.history_uri(params = {})
      URI(history_url(params))
    end

    def self.user_uri(params = {})
      params.merge!(token_param)
      URI("#{BASE_URL}users.info?#{params.to_query}")
    end

    def self.bot_uri(params = {})
      params.merge!(token_param)
      URI("#{BASE_URL}bots.info?#{params.to_query}")
    end

    def self.messages(channel, count)
      return { "error": I18n.t('slack.errors.access_token_is_empty') } if SiteSetting.slack_access_token.empty?

      get_request(history_uri( channel: channel, count: count ))
    end

    def self.message(channel, ts)
      return { "error": I18n.t('slack.errors.access_token_is_empty') } if SiteSetting.slack_access_token.empty?

      get_request(history_uri( channel: channel, latest: ts, count: 1, inclusive: true ))
    end

    def self.user(id)
      return { "error": I18n.t('slack.errors.access_token_is_empty') } if SiteSetting.slack_access_token.empty?

      get_request(user_uri( user: id ))
    end

    def self.bot(id)
      return { "error": I18n.t('slack.errors.access_token_is_empty') } if SiteSetting.slack_access_token.empty?

      get_request(bot_uri( bot: id ))
    end

    private

      def self.token_param
        { token: SiteSetting.slack_access_token }
      end

  end
end
