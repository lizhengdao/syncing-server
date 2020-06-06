module SyncEngine
  class AbstractUserManager
    def initialize(user_class)
      @user_class = user_class
    end

    def verify_credentials(email, password)
      user = @user_class.find_by_email(email)
      user && test_password(password, user.encrypted_password)
    end

    def sign_in(email, password, params, user_agent)
      user = @user_class.find_by_email(email)
      if verify_credentials(email, password)
        create_jwt_or_session(user, params, user_agent)
      else
        { error: { message: 'Invalid email or password.', status: 401 } }
      end
    end

    def register(email, password, params, user_agent = '')
      user = @user_class.find_by_email(email)
      if user
        { error: { message: 'This email is already registered.', status: 401 } }
      else
        user = @user_class.new(email: email, encrypted_password: hash_password(password))
        user.update!(registration_params(params))
        create_jwt_or_session(user, params, user_agent)
      end
    end

    def change_pw(user, password, params, user_agent = '')
      current_protocol_version = user.version.to_i
      new_protocol_version = params[:version].to_i || current_protocol_version

      upgrading_protocol_version = new_protocol_version > current_protocol_version

      user.encrypted_password = hash_password(password)
      user.update!(registration_params(params))

      # We want to create a new session only if upgrading from a protocol version that does not
      # support sessions (i.e: 003 to 004).
      if (upgrading_protocol_version && new_protocol_version == @user_class::SESSIONS_PROTOCOL_VERSION)
        create_session(user, params, user_agent)
      # If the user is on a client that supports a maximum protocol version of 003, then we want
      # to issue a new JWT with updated claims.
      elsif user.supports_jwt?
        create_jwt(user)
      else
        { user: user }
      end
    end

    def update(user, params)
      user.update!(registration_params(params))

      result = { user: user }

      if user.supports_jwt?
        result[:token] = jwt(user)
      end

      result
    end

    def auth_params(email)
      user = @user_class.find_by_email(email)

      unless user
        return nil
      end

      auth_params = {
        identifier: user.email,
        pw_cost: user.pw_cost,
        pw_nonce: user.pw_nonce,
        version: user.version,
      }

      if user.pw_salt
        # v002 only
        auth_params[:pw_salt] = user.pw_salt
      end

      if user.pw_func
        # v001 only
        auth_params[:pw_func] = user.pw_func
        auth_params[:pw_alg] = user.pw_alg
        auth_params[:pw_key_size] = user.pw_key_size
      end

      auth_params
    end

    private

    require 'bcrypt'

    DEFAULT_COST = 11

    def hash_password(password)
      BCrypt::Password.create(password, cost: DEFAULT_COST).to_s
    end

    def test_password(password, hash)
      bcrypt = BCrypt::Password.new(hash)
      password = BCrypt::Engine.hash_secret(password, bcrypt.salt)
      ActiveSupport::SecurityUtils.secure_compare(password, hash)
    end

    def jwt(user)
      JwtHelper.encode(user_uuid: user.uuid, pw_hash: Digest::SHA256.hexdigest(user.encrypted_password))
    end

    def registration_params(params)
      params.permit(:pw_func, :pw_alg, :pw_cost, :pw_key_size, :pw_nonce, :pw_salt, :version)
    end

    def create_jwt(user)
      { user: user, token: jwt(user) }
    end

    def create_session(user, params, user_agent)
      session = Session.new(user_uuid: user.uuid, api_version: params[:api], user_agent: user_agent)

      unless session.save
        return { error: { message: 'Could not create a session.', status: 400 } }
      end

      response = session.response_hash
      response[:user] = user
      response
    end

    def create_jwt_or_session(user, params, user_agent)
      if user.supports_jwt?
        return create_jwt(user)
      end

      create_session(user, params, user_agent)
    end

    deprecate :update
  end
end
