module Doorkeeper
  class MissingConfiguration < StandardError
    def initialize
      super('Configuration for doorkeeper missing. Do you have doorkeeper initializer?')
    end
  end

  def self.configure(&block)
    @config = Config::Builder.new(&block).build
    setup_orm_adapter
    setup_orm_models
    setup_application_owner if @config.enable_application_owner?
    check_requirements
  end

  def self.configuration
    @config || (fail MissingConfiguration.new)
  end

  def self.check_requirements
    @orm_adapter.check_requirements!(configuration)
  end

  def self.setup_orm_adapter
    @orm_adapter = "doorkeeper/orm/#{configuration.orm}".classify.constantize
  rescue NameError => e
    fail e, "ORM adapter not found (#{configuration.orm})", <<-ERROR_MSG.squish
[doorkeeper] ORM adapter not found (#{configuration.orm}), or there was an error
trying to load it.

You probably need to add the related gem for this adapter to work with
doorkeeper.
      ERROR_MSG
  end

  def self.setup_orm_models
    @orm_adapter.initialize_models!
  end

  def self.setup_application_owner
    @orm_adapter.initialize_application_owner!
  end

  class Config
    class Builder
      def initialize(&block)
        @config = Config.new
        instance_eval(&block)
      end

      def build
        @config
      end

      def enable_application_owner(opts = {})
        @config.instance_variable_set('@enable_application_owner', true)
        confirm_application_owner if opts[:confirmation].present? && opts[:confirmation]
      end

      def confirm_application_owner
        @config.instance_variable_set('@confirm_application_owner', true)
      end

      def default_scopes(*scopes)
        @config.instance_variable_set('@default_scopes', OAuth::Scopes.from_array(scopes))
      end

      def optional_scopes(*scopes)
        @config.instance_variable_set('@optional_scopes', OAuth::Scopes.from_array(scopes))
      end

      def client_credentials(*methods)
        @config.instance_variable_set('@client_credentials', methods)
      end

      def access_token_methods(*methods)
        @config.instance_variable_set('@access_token_methods', methods)
      end

      def use_refresh_token
        @config.instance_variable_set('@refresh_token_enabled', true)
      end

      def realm(realm)
        @config.instance_variable_set('@realm', realm)
      end

      def reuse_access_token
        @config.instance_variable_set("@reuse_access_token", true)
      end

      def force_ssl_in_redirect_uri(boolean)
        @config.instance_variable_set("@force_ssl_in_redirect_uri", boolean)
      end

      def access_token_generator(access_token_generator)
        @config.instance_variable_set(
          '@access_token_generator', access_token_generator
        )
      end
    end

    module Option
      # Defines configuration option
      #
      # When you call option, it defines two methods. One method will take place
      # in the +Config+ class and the other method will take place in the
      # +Builder+ class.
      #
      # The +name+ parameter will set both builder method and config attribute.
      # If the +:as+ option is defined, the builder method will be the specified
      # option while the config attribute will be the +name+ parameter.
      #
      # If you want to introduce another level of config DSL you can
      # define +builder_class+ parameter.
      # Builder should take a block as the initializer parameter and respond to function +build+
      # that returns the value of the config attribute.
      #
      # ==== Options
      #
      # * [:+as+] Set the builder method that goes inside +configure+ block
      # * [+:default+] The default value in case no option was set
      #
      # ==== Examples
      #
      #    option :name
      #    option :name, as: :set_name
      #    option :name, default: 'My Name'
      #    option :scopes builder_class: ScopesBuilder
      #
      def option(name, options = {})
        attribute = options[:as] || name
        attribute_builder = options[:builder_class]

        Builder.instance_eval do
          define_method name do |*args, &block|
            # TODO: is builder_class option being used?
            value = unless attribute_builder
                      block ? block : args.first
                    else
                      attribute_builder.new(&block).build
                    end

            @config.instance_variable_set(:"@#{attribute}", value)
          end
        end

        define_method attribute do |*args|
          if instance_variable_defined?(:"@#{attribute}")
            instance_variable_get(:"@#{attribute}")
          else
            options[:default]
          end
        end

        public attribute
      end

      def extended(base)
        base.send(:private, :option)
      end
    end

    extend Option

    option :resource_owner_authenticator,
           as: :authenticate_resource_owner,
           default: (lambda do |_routes|
             logger.warn(I18n.translate('doorkeeper.errors.messages.resource_owner_authenticator_not_configured'))
             nil
           end)
    option :admin_authenticator,
           as: :authenticate_admin,
           default: ->(_routes) {}
    option :resource_owner_from_credentials,
           default: (lambda do |_routes|
             warn(I18n.translate('doorkeeper.errors.messages.credential_flow_not_configured'))
             nil
           end)

    option :skip_authorization,             default: ->(_routes) {}
    option :access_token_expires_in,        default: 7200
    option :custom_access_token_expires_in, default: lambda { |_app| nil }
    option :authorization_code_expires_in,  default: 600
    option :orm,                            default: :active_record
    option :native_redirect_uri,            default: 'urn:ietf:wg:oauth:2.0:oob'
    option :active_record_options,          default: {}
    option :realm,                          default: 'Doorkeeper'
    option :force_ssl_in_redirect_uri,      default: !Rails.env.development?
    option :grant_flows,                    default: {
                                                       authorization_code: Doorkeeper::Request::AuthorizationCode,
                                                       client_credentials: Doorkeeper::Request::ClientCredentials
                                                     }
    option :access_token_generator,         default: "Doorkeeper::OAuth::Helpers::UniqueToken"

    attr_reader :reuse_access_token

    def refresh_token_enabled?
      !!@refresh_token_enabled
    end

    def enable_application_owner?
      !!@enable_application_owner
    end

    def confirm_application_owner?
      !!@confirm_application_owner
    end

    def default_scopes
      @default_scopes ||= OAuth::Scopes.new
    end

    def optional_scopes
      @optional_scopes ||= OAuth::Scopes.new
    end

    def scopes
      @scopes ||= default_scopes + optional_scopes
    end

    def client_credentials_methods
      @client_credentials ||= [:from_basic, :from_params]
    end

    def access_token_methods
      @access_token_methods ||= [:from_bearer_authorization, :from_access_token_param, :from_bearer_param]
    end

    def realm
      @realm ||= 'Doorkeeper'
    end

    def authorization_response_types
      @authorization_response_types ||= calculate_authorization_response_types
    end

    def token_grant_types
      @token_grant_types ||= calculate_token_grant_types
    end

    private

    # Determines what values are acceptable for 'response_type' param in
    # authorization request endpoint, and return them as an array of strings.
    #
    def calculate_authorization_response_types
      types = []
      types << 'code'  if grant_flows.include? 'authorization_code'
      types << 'token' if grant_flows.include? 'implicit'
      types
    end

    # Determines what values are acceptable for 'grant_type' param token
    # request endpoint, and return them in array.
    #
    def calculate_token_grant_types
      types = grant_flows
      types['refresh_token'] = Doorkeeper::Request::RefreshToken if refresh_token_enabled?
      types
    end
  end
end
