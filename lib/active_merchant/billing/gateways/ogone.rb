# coding: utf-8
require 'rexml/document'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    # = Ogone DirectLink Gateway
    #
    # DirectLink is the API version of the Ogone Payment Platform. It allows server to server
    # communication between Ogone systems and your e-commerce website.
    #
    # This implementation follows the specification provided in the DirectLink integration
    # guide version 4.0 (24 February 2011), available here:
    # https://secure.ogone.com/ncol/Ogone_DirectLink_EN.pdf
    #
    # It also features aliases, which allow to store/unstore credit cards, as specified in
    # the Alias Manager Option guide version 3.0 (24 February 2011) available here:
    # https://secure.ogone.com/ncol/Ogone_Alias_EN.pdf
    #
    # It also implements the 3-D Secure feature, as specified in the DirectLink with 3D Secure guide version 3.0 available here:
    # https://secure.ogone.com/ncol/Ogone_DirectLink-3-D_EN.pdf
    #
    #
    # It was last tested on Release 04.87 of Ogone DirectLink + AliasManager + DirectLink with 3D Secure (24 February 2011).
    #
    # For any questions or comments, please contact Nicolas Jacobeus (nj@belighted.com) or Sébastien Grosjean (public@zencocoon.com).
    #
    # == Example use:
    #
    #   gateway = ActiveMerchant::Billing::OgoneGateway.new(
    #               :login     => "my_ogone_psp_id",
    #               :user      => "my_ogone_user_id",
    #               :password  => "my_ogone_pswd",
    #               :created_after_10_may_2010 => true      # must be set to true if your account was created after 10 May 2010. This is due to the new SHA-1/256/512 signature process
    #               :signature => "my_ogone_sha_signature", # extra security, only if you configured your Ogone environment so
    #               :signature_encryptor => "sha512",       # can be "sha1" (default), "sha256" or "sha512", must be the same as the one configured in your Ogone account
    #            )
    #
    #   # set up credit card obj as in main ActiveMerchant example
    #   creditcard = ActiveMerchant::Billing::CreditCard.new(
    #     :type       => 'visa',
    #     :number     => '4242424242424242',
    #     :month      => 8,
    #     :year       => 2009,
    #     :first_name => 'Bob',
    #     :last_name  => 'Bobsen'
    #   )
    #
    #   # run request
    #   response = gateway.purchase(1000, creditcard, :order_id => "1") # charge 10 EUR
    #
    #   If you don't provide an :order_id, the gateway will generate a random one for you.
    #
    #   puts response.success?      # Check whether the transaction was successful
    #   puts response.message       # Retrieve the message returned by Ogone
    #   puts response.authorization # Retrieve the unique transaction ID returned by Ogone
    #
    #   To use the alias feature, simply add :store in the options hash:
    #
    #   gateway.purchase(1000, creditcard,          :order_id => "1", :store => "myawesomecustomer") # associates the alias to that creditcard
    #   gateway.purchase(2000, "myawesomecustomer", :order_id => "2") # You can use the alias instead of the creditcard for subsequent orders
    #
    #   To use the 3D-Secure feature, simply add :d3d => true in the options hash:
    #   gateway.purchase(2000, "myawesomecustomer", :order_id => "2", :d3d => true)
    #
    #   Specific 3-D Secure request options are (please refer to the documentation for more infos about these options):
    #   :win3ds          => :main_window (default), :pop_up or :pop_ix.
    #   :http_accept     => "*/*" (default), or any other HTTP_ACCEPT header value.
    #   :http_user_agent => The cardholder's User-Agent string
    #   :accept_url      => URL of the web page to show the customer when the payment is authorized. (or waiting to be authorized).
    #   :decline_url     => URL of the web page to show the customer when the acquirer rejects the authorization more than the maximum permitted number of authorization attempts (10 by default, but can be changed in the "Global transaction parameters" tab, "Payment retry" section of the Technical Information page).
    #   :exception_url   => URL of the web page to show the customer when the payment result is uncertain.
    #   :paramplus       => Field to submit the miscellaneous parameters and their values that you wish to be returned in the post sale request or final redirection.
    #   :complus         => Field to submit a value you wish to be returned in the post sale request or output.
    #   :language        => Customer's language, for example: "en_EN"
    class OgoneGateway < Gateway

      URLS = {
        :order       => 'https://secure.ogone.com/ncol/%s/orderdirect.asp',
        :maintenance => 'https://secure.ogone.com/ncol/%s/maintenancedirect.asp'
      }

      CVV_MAPPING = { 'OK' => 'M',
                      'KO' => 'N',
                      'NO' => 'P' }

      AVS_MAPPING = { 'OK' => 'M',
                      'KO' => 'N',
                      'NO' => 'R' }

      THREE_D_SECURE_DISPLAY_WAYS = { :main_window => 'MAINW',  # display the identification page in the main window (default value).
                                      :pop_up      => 'POPUP',  # display the identification page in a pop-up window and return to the main window at the end.
                                      :pop_ix      => 'POPIX' } # display the identification page in a pop-up window and remain in the pop-up window.

      SUCCESS_MESSAGE = "The transaction was successful"

      self.supported_countries = ['BE', 'DE', 'FR', 'NL', 'AT', 'CH']
      # also supports Airplus and UATP
      self.supported_cardtypes = [:visa, :master, :american_express, :diners_club, :discover, :jcb, :maestro]
      self.homepage_url = 'http://www.ogone.com/'
      self.display_name = 'Ogone'
      self.default_currency = 'EUR'
      self.money_format = :cents

      def initialize(options = {})
        requires!(options, :login, :user, :password)
        @options = options
        super
      end

      # Verify and reserve the specified amount on the account, without actually doing the transaction.
      def authorize(money, payment_source, options = {})
        post = {}
        add_invoice(post, options)
        add_payment_source(post, payment_source, options)
        add_address(post, payment_source, options)
        add_customer_data(post, options)
        add_money(post, money, options)
        commit('RES', post)
      end

      # Verify and transfer the specified amount.
      def purchase(money, payment_source, options = {})
        post = {}
        add_invoice(post, options)
        add_payment_source(post, payment_source, options)
        add_address(post, payment_source, options)
        add_customer_data(post, options)
        add_money(post, money, options)
        commit('SAL', post)
      end

      # Complete a previously authorized transaction.
      def capture(money, authorization, options = {})
        post = {}
        add_authorization(post, reference_from(authorization))
        add_invoice(post, options)
        add_customer_data(post, options)
        add_money(post, money, options)
        commit('SAL', post)
      end

      # Cancels a previously authorized transaction.
      def void(identification, options = {})
        post = {}
        add_authorization(post, reference_from(identification))
        commit('DES', post)
      end

      # Credit the specified account by a specific amount.
      def credit(money, identification_or_credit_card, options = {})
        if reference_transaction?(identification_or_credit_card)
          deprecated CREDIT_DEPRECATION_MESSAGE
          # Referenced credit: refund of a settled transaction
          refund(money, identification_or_credit_card, options)
        else # must be a credit card or card reference
          perform_non_referenced_credit(money, identification_or_credit_card, options)
        end
      end

      # Refund of a settled transaction
      def refund(money, reference, options = {})
        perform_reference_credit(money, reference, options)
      end

      def test?
        @options[:test] || super
      end

      private

      def reference_from(authorization)
        authorization.split(";").first
      end

      def reference_transaction?(identifier)
        return false unless identifier.is_a?(String)
        reference, action = identifier.split(";")
        !action.nil?
      end

      def perform_reference_credit(money, payment_target, options = {})
        post = {}
        add_authorization(post, reference_from(payment_target))
        add_money(post, money, options)
        commit('RFD', post)
      end

      def perform_non_referenced_credit(money, payment_target, options = {})
        # Non-referenced credit: acts like a reverse purchase
        post = {}
        add_invoice(post, options)
        add_payment_source(post, payment_target, options)
        add_address(post, payment_target, options)
        add_customer_data(post, options)
        add_money(post, money, options)
        commit('RFD', post)
      end

      def add_payment_source(post, payment_source, options)
        if payment_source.is_a?(String)
          add_alias(post, payment_source)
          add_eci(post, '9')
        else
          add_alias(post, options[:store])
          if options[:d3d]
            add_pair post, 'FLAG3D', 'Y'
            win3ds = THREE_D_SECURE_DISPLAY_WAYS.key?(options[:win_3d]) ? THREE_D_SECURE_DISPLAY_WAYS[options[:win_3d]] : THREE_D_SECURE_DISPLAY_WAYS[:main_window]
            add_pair post, 'WIN3DS', win3ds

            add_pair post, 'HTTP_ACCEPT',     options[:http_accept] || "*/*"
            add_pair post, 'HTTP_USER_AGENT', options[:http_user_agent] if options[:http_user_agent]
            add_pair post, 'ACCEPTURL',       options[:accept_url]      if options[:accept_url]
            add_pair post, 'DECLINEURL',      options[:decline_url]     if options[:decline_url]
            add_pair post, 'EXCEPTIONURL',    options[:exception_url]   if options[:exception_url]
            add_pair post, 'PARAMPLUS',       options[:paramplus]       if options[:paramplus]
            add_pair post, 'COMPLUS',         options[:complus]         if options[:complus]
            add_pair post, 'LANGUAGE',        options[:language]        if options[:language]
            add_pair post, 'TP',              options[:tp]              if options[:tp]
          end
          
          add_creditcard(post, payment_source)
        end
      end

      def add_eci(post, eci)
        add_pair post, 'ECI', eci
      end

      def add_alias(post, _alias)
        add_pair post, 'ALIAS', _alias
      end

      def add_authorization(post, authorization)
        add_pair post, 'PAYID', authorization
      end

      def add_money(post, money, options)
        add_pair post, 'currency', options[:currency] || @options[:currency] || currency(money)
        add_pair post, 'amount',   amount(money)
      end

      def add_customer_data(post, options)
        add_pair post, 'EMAIL',       options[:email]
        add_pair post, 'REMOTE_ADDR', options[:ip]
      end

      def add_address(post, creditcard, options)
        return unless options[:billing_address]
        add_pair post, 'Owneraddress', options[:billing_address][:address1]
        add_pair post, 'OwnerZip',     options[:billing_address][:zip]
        add_pair post, 'ownertown',    options[:billing_address][:city]
        add_pair post, 'ownercty',     options[:billing_address][:country]
        add_pair post, 'ownertelno',   options[:billing_address][:phone]
      end

      def add_invoice(post, options)
        add_pair post, 'orderID', options[:order_id] || generate_unique_id[0...30]
        add_pair post, 'COM',     options[:description]
      end

      def add_creditcard(post, creditcard)
        add_pair post, 'CN',     creditcard.name
        add_pair post, 'CARDNO', creditcard.number
        add_pair post, 'ED',     "%02d%02s" % [creditcard.month, creditcard.year.to_s[-2..-1]]
        add_pair post, 'CVC',    creditcard.verification_value
      end

      def parse(body)
        xml_root = REXML::Document.new(body).root
        response = convert_attributes_to_hash(xml_root.attributes)

        # Add HTML_ANSWER element (3-D Secure specific to the response's params)
        # Note: HTML_ANSWER is not an attribute so we add it "by hand" to the response
        if html_answer = REXML::XPath.first(xml_root, "//HTML_ANSWER")
          response["HTML_ANSWER"] = html_answer.text
        end

        response
      end

      def commit(action, parameters)
        add_pair parameters, 'PSPID',  @options[:login]
        add_pair parameters, 'USERID', @options[:user]
        add_pair parameters, 'PSWD',   @options[:password]

        url = URLS[parameters['PAYID'] ? :maintenance : :order] % [test? ? "test" : "prod"]
        response = parse(ssl_post(url, post_data(action, parameters)))

        options = {
          :authorization => [response["PAYID"], action].join(";"),
          :test          => test?,
          :avs_result    => { :code => AVS_MAPPING[response["AAVCheck"]] },
          :cvv_result    => CVV_MAPPING[response["CVCCheck"]]
        }
        Response.new(successful?(response), message_from(response), response, options)
      end

      def successful?(response)
        response["NCERROR"] == "0"
      end

      def message_from(response)
        if successful?(response)
          SUCCESS_MESSAGE
        else
          format_error_message(response["NCERRORPLUS"])
        end
      end

      def format_error_message(message)
        raw_message = message.to_s.strip
        case raw_message
        when /\|/
          raw_message.split("|").join(", ").capitalize
        when /\//
          raw_message.split("/").first.to_s.capitalize
        else
          raw_message.to_s.capitalize
        end
      end

      def post_data(action, parameters = {})
        add_pair parameters, 'Operation', action
        add_signature(parameters) if @options[:signature] # the user wants a SHA-1 signature

        parameters.map { |key, value| "#{key}=#{CGI.escape(value.to_s)}" }.join("&")
      end

      def add_signature(parameters)
        sha_encryptor = case @options[:signature_encryptor]
        when 'sha256'
          Digest::SHA256
        when 'sha512'
          Digest::SHA512
        else
          Digest::SHA1
        end

        string_to_digest = if @options[:created_after_10_may_2010]
          parameters.sort { |a, b| a[0].upcase <=> b[0].upcase }.map { |k, v| "#{k.upcase}=#{v}" }.join(@options[:signature])
        else
          %w[orderID amount currency CARDNO PSPID Operation ALIAS].map { |key| parameters[key] }.join
        end + @options[:signature]

        add_pair parameters, 'SHASign', sha_encryptor.hexdigest(string_to_digest).upcase
      end

      def add_pair(post, key, value)
        post[key] = value if !value.blank?
      end

      def convert_attributes_to_hash(rexml_attributes)
        response_hash = {}
        rexml_attributes.each do |key, value|
          response_hash[key] = value
        end
        response_hash
      end
    end
  end
end
