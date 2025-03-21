import passport from "@outlinewiki/koa-passport";
import type { Context } from "koa";
import Router from "koa-router";
import get from "lodash/get";
import { Strategy } from "passport-oauth2";
import { slugifyDomain } from "@shared/utils/domains";
import { parseEmail } from "@shared/utils/email";
import accountProvisioner from "@server/commands/accountProvisioner";
import {
  OIDCMalformedUserInfoError,
  AuthenticationError,
} from "@server/errors";
import passportMiddleware from "@server/middlewares/passport";
import { AuthenticationProvider, User } from "@server/models";
import { AuthenticationResult } from "@server/types";
import {
  StateStore,
  getTeamFromContext,
  getClientFromContext,
  request,
} from "@server/utils/passport";
import config from "../../plugin.json";
import env from "../env";
import Logger from "@server/logging/Logger";

const router = new Router();
const scopes = env.OIDC_SCOPES.split(" ");

const authorizationParams = Strategy.prototype.authorizationParams;
Strategy.prototype.authorizationParams = function (options) {
  return {
    ...(options.originalQuery || {}),
    ...(authorizationParams.bind(this)(options) || {}),
  };
};

const authenticate = Strategy.prototype.authenticate;
Strategy.prototype.authenticate = function (req, options) {
  options.originalQuery = req.query;
  authenticate.bind(this)(req, options);
};

if (
  env.OIDC_CLIENT_ID &&
  env.OIDC_CLIENT_SECRET &&
  env.OIDC_AUTH_URI &&
  env.OIDC_TOKEN_URI &&
  env.OIDC_USERINFO_URI
) {
  passport.use(
    config.id,
    new Strategy(
      {
        authorizationURL: env.OIDC_AUTH_URI,
        tokenURL: env.OIDC_TOKEN_URI,
        clientID: env.OIDC_CLIENT_ID,
        clientSecret: env.OIDC_CLIENT_SECRET,
        callbackURL: `${env.URL}/auth/${config.id}.callback`,
        passReqToCallback: true,
        scope: env.OIDC_SCOPES,
        // @ts-expect-error custom state store
        store: new StateStore(),
        state: true,
        pkce: false,
      },
      // OpenID Connect standard profile claims can be found in the official
      // specification.
      // https://openid.net/specs/openid-connect-core-1_0.html#StandardClaims
      // Non-standard claims may be configured by individual identity providers.
      // Any claim supplied in response to the userinfo request will be
      // available on the `profile` parameter
      async function (
        ctx: Context,
        accessToken: string,
        refreshToken: string,
        params: { expires_in: number, id_token?: string },
        _profile: unknown,
        done: (
          err: Error | null,
          user: User | null,
          result?: AuthenticationResult
        ) => void
      ) {
        try {
          // Some providers require a POST request to the userinfo endpoint, add them as exceptions here.
          const usePostMethod = [
            "https://api.dropboxapi.com/2/openid/userinfo",
          ];

          const profile = await request(
          usePostMethod.includes(env.OIDC_USERINFO_URI!) ? "POST" : "GET",
          env.OIDC_USERINFO_URI!,
          accessToken
          );

          // Extract claims from ID token if available
          if (params.id_token) {
            try {
              // Parse ID token (it's a JWT)
              const tokenParts = params.id_token.split('.');
              if (tokenParts.length >= 2) {
                const tokenPayload = JSON.parse(
                  Buffer.from(tokenParts[1], 'base64').toString()
                );

                // Merge ID token claims into profile
                // This makes claims like 'upn' available in the profile object
                Object.assign(profile, tokenPayload);

                Logger.info("authentication", `ID token parsed and merged with profile`);
              }
            } catch (tokenError) {
              Logger.error("authentication", `Failed to parse ID token: ${tokenError.message}`);
            }
          }

          Logger.info("authentication", `Profile data after merge: ${JSON.stringify(profile)}`);

          if (!profile.email) {
            throw AuthenticationError(
              `An email field was not returned in the profile parameter, but is required.`
            );
          }
          const team = await getTeamFromContext(ctx);
          const client = getClientFromContext(ctx);
          const { domain } = parseEmail(profile.email);

          // Only a single OIDC provider is supported – find the existing, if any.
          const authenticationProvider = team
            ? (await AuthenticationProvider.findOne({
                where: {
                  name: "oidc",
                  teamId: team.id,
                  providerId: domain,
                },
              })) ??
              (await AuthenticationProvider.findOne({
                where: {
                  name: "oidc",
                  teamId: team.id,
                },
              }))
            : undefined;

          // Derive a providerId from the OIDC location if there is no existing provider.
          const oidcURL = new URL(env.OIDC_AUTH_URI!);
          const providerId =
            authenticationProvider?.providerId ?? oidcURL.hostname;

          if (!domain) {
            throw OIDCMalformedUserInfoError();
          }

          // remove the TLD and form a subdomain from the remaining
          const subdomain = slugifyDomain(domain);

          // Claim name can be overriden using an env variable.
          // Default is 'preferred_username' as per OIDC spec.
          const username = get(profile, env.OIDC_USERNAME_CLAIM);
          const name = profile.name || username || profile.username;
          const profileId = profile.sub ? profile.sub : profile.id;

          if (!name) {
            throw AuthenticationError(
              `Neither a name or username was returned in the profile parameter, but at least one is required.`
            );
          }

          Logger.info("authentication", `Profile data received: ${JSON.stringify(profile)}`);
          Logger.info("authentication", `OIDC_EMAIL_CLAIM configured as: ${env.OIDC_EMAIL_CLAIM}`);
          Logger.info("authentication", `UPN value: ${profile.upn}`);
          Logger.info("authentication", `Email value: ${profile.email}`);
          Logger.info("authentication", `Available profile fields: ${Object.keys(profile).join(', ')}`);

          const email = get(profile, env.OIDC_EMAIL_CLAIM) || profile.email;
          Logger.info("authentication", `Email selected for authentication: ${email}`);

          const usernamecheck = email.split('@')[0];

          try {
            if (!env.ACCESS_API) {
              throw new AuthenticationError("Access control system is not properly configured");
            }

            Logger.info("authentication", `Starting authentication for user: ${usernamecheck}`);
            Logger.info("authentication", `ACCESS_API configured as: ${env.ACCESS_API || 'not set'}`);
            Logger.info("authentication", `Attempting to contact access control API at: ${env.ACCESS_API}`);

            let accessResponse;
            try {
              accessResponse = await Promise.race([
                request('GET', `${env.ACCESS_API}?username=${usernamecheck}`, ''),
                new Promise((_, reject) =>
                  setTimeout(() => reject(new Error('Access API timeout')), 5000)
                )
              ]);

              Logger.info("authentication", `Access API raw response: ${JSON.stringify(accessResponse)}`);
              Logger.info("authentication", `Access check result: ${accessResponse?.has_access}`);

            } catch (requestError) {
              Logger.info("authentication", `Access API request error: ${requestError.message}`);
              throw new AuthenticationError(`Access check failed: ${requestError.message}`);
            }

            if (!accessResponse) {
              throw new AuthenticationError('No response from access control API');
            }

            if (typeof accessResponse !== 'object' || accessResponse === null) {
              throw new AuthenticationError('Invalid response from access control API');
            }

            if (typeof accessResponse.has_access !== 'boolean') {
              throw new AuthenticationError('Invalid response format from access control API');
            }
            if (!accessResponse.has_access) {
              throw new AuthenticationError('User does not have required access permissions');
            }
          } catch (err) {
            Logger.info("authentication", `Access check error: ${err.message}, code: ${err.code || 'none'}`);

            if (err.code === 'ECONNREFUSED' || err.code === 'ENOTFOUND') {
              Logger.info("authentication", `Network error connecting to access API: ${err.code} - ${err.message}`);
            }

            if (err.message === 'Access API timeout') {
              Logger.info("authentication", `Access API timed out after 5000ms`);
            }

            if (
              err.code === 'ECONNREFUSED' ||
              err.code === 'ENOTFOUND' ||
              err.message === 'Access API timeout' ||
              err.message.includes('Access check failed')
            ) {
              return done(new AuthenticationError('Access control system unavailable'), null);
            }

            return done(err, null);
          }

          const result = await accountProvisioner({
            ip: ctx.ip,
            team: {
              teamId: team?.id,
              name: env.APP_NAME,
              domain,
              subdomain,
            },
            user: {
              name,
              email: profile.email,
              avatarUrl: profile.picture,
            },
            authenticationProvider: {
              name: config.id,
              providerId,
            },
            authentication: {
              providerId: profileId,
              accessToken,
              refreshToken,
              expiresIn: params.expires_in,
              scopes,
            },
          });
          return done(null, result.user, { ...result, client });
        } catch (err) {
          return done(err, null);
        }
      }
    )
  );

  router.get(config.id, passport.authenticate(config.id));
  router.get(`${config.id}.callback`, passportMiddleware(config.id));
  router.post(`${config.id}.callback`, passportMiddleware(config.id));
}

export default router;