#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$1" == apache2* ]] || [ "$1" = 'php-fpm' ]; then
	uid="$(id -u)"
	gid="$(id -g)"
	if [ "$uid" = '0' ]; then
		case "$1" in
			apache2*)
				user="${APACHE_RUN_USER:-www-data}"
				group="${APACHE_RUN_GROUP:-www-data}"

				# strip off any '#' symbol ('#1000' is valid syntax for Apache)
				pound='#'
				user="${user#$pound}"
				group="${group#$pound}"
				;;
			*) # php-fpm
				user='www-data'
				group='www-data'
				;;
		esac
	else
		user="$uid"
		group="$gid"
	fi

	if [ ! -e index.php ] && [ ! -e wp-includes/version.php ]; then
		# if the directory exists and WordPress doesn't appear to be installed AND the permissions of it are root:root, let's chown it (likely a Docker-created directory)
		if [ "$uid" = '0' ] && [ "$(stat -c '%u:%g' .)" = '0:0' ]; then
			chown "$user:$group" .
		fi

		echo >&2 "WordPress not found in $PWD - copying now..."
		if [ -n "$(find -mindepth 1 -maxdepth 1 -not -name wp-content)" ]; then
			echo >&2 "WARNING: $PWD is not empty! (copying anyhow)"
		fi
		sourceTarArgs=(
			--create
			--file -
			--directory /usr/src/wordpress
			--owner "$user" --group "$group"
		)
		targetTarArgs=(
			--extract
			--file -
		)
		if [ "$uid" != '0' ]; then
			# avoid "tar: .: Cannot utime: Operation not permitted" and "tar: .: Cannot change mode to rwxr-xr-x: Operation not permitted"
			targetTarArgs+=( --no-overwrite-dir )
		fi
		# loop over "pluggable" content in the source, and if it already exists in the destination, skip it
		# https://github.com/docker-library/wordpress/issues/506 ("wp-content" persisted, "akismet" updated, WordPress container restarted/recreated, "akismet" downgraded)
		for contentPath in \
			/usr/src/wordpress/.htaccess \
			/usr/src/wordpress/wp-content/*/*/ \
		; do
			contentPath="${contentPath%/}"
			[ -e "$contentPath" ] || continue
			contentPath="${contentPath#/usr/src/wordpress/}" # "wp-content/plugins/akismet", etc.
			if [ -e "$PWD/$contentPath" ]; then
				echo >&2 "WARNING: '$PWD/$contentPath' exists! (not copying the WordPress version)"
				sourceTarArgs+=( --exclude "./$contentPath" )
			fi
		done
		tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}"
		echo >&2 "Complete! WordPress has been successfully copied to $PWD"
	fi

	wpEnvs=( "${!WORDPRESS_@}" )
	if [ ! -s wp-config.php ] && [ "${#wpEnvs[@]}" -gt 0 ]; then
		for wpConfigDocker in \
			wp-config-docker.php \
			/usr/src/wordpress/wp-config-docker.php \
		; do
			if [ -s "$wpConfigDocker" ]; then
				echo >&2 "No 'wp-config.php' found in $PWD, but 'WORDPRESS_...' variables supplied; copying '$wpConfigDocker' (${wpEnvs[*]})"
				# using "awk" to replace all instances of "put your unique phrase here" with a properly unique string (for AUTH_KEY and friends to have safe defaults if they aren't specified with environment variables)
				awk '
					/put your unique phrase here/ {
						cmd = "head -c1m /dev/urandom | sha1sum | cut -d\\  -f1"
						cmd | getline str
						close(cmd)
						gsub("put your unique phrase here", str)
					}
					{ print }
				' "$wpConfigDocker" > wp-config.php
				if [ "$uid" = '0' ]; then
					# attempt to ensure that wp-config.php is owned by the run user
					# could be on a filesystem that doesn't allow chown (like some NFS setups)
					chown "$user:$group" wp-config.php || true
				fi
				break
			fi
		done
	fi
fi

echo $ADMIN_PASS > admin_pass.txt

ls -l /mnt/efs1


# Remove the wp-config directory and create a symlink to the wp-config
if [ ! -f /mnt/efs1/wp-config.php ]; then
	echo "We should install wordpress"
	wp config create --dbname=$DB_NAME --dbuser=$DB_USER --dbpass=$DB_PASS --dbhost=$DB_HOST --dbuser=$DB_USER --allow-root
	if wp core is-installed --allow-root; then
		echo "skipping installing core"
	else
		wp core install --url=$SITE_URL --title="$SITE_TITLE" --admin_user="$ADMIN_USER" --admin_email="$ADMIN_EMAIL" --prompt=admin_password < admin_pass.txt  --allow-root
		wp option update siteurl "https://$SITE_URL" --allow-root
		wp plugin install ssl-insecure-content-fixer --allow-root
		wp plugin activate ssl-insecure-content-fixer --allow-root
		wp option add ssl_insecure_content_fixer --format=json < ssl-settings.json --allow-root
		mv wp-config.php /mnt/efs1/
	fi
fi

mv /var/www/html/wp-config.php /mnt/efs1/wp-config.php
ln -s /mnt/efs1/wp-config.php /var/www/html/wp-config.php

echo "got past installing wordpress"

# If the wp-content directory doesn't exist in the efs filesystem, move the docker-based wp-content directory to the efs filesystem
# and create a symlink here.
if [ ! -d /mnt/efs1/wp-content ]; then
  mv /var/www/html/wp-content /mnt/efs1/wp-content
  ln -s /mnt/efs1/wp-content /var/www/html/wp-content
else
	rm -rf /var/www/html/wp-content
	ln -s /mnt/efs1/wp-content wp-content
fi

# If the plugins and themes directories do not exist in the efs filesystem, create them
if [ ! -d /mnt/efs1/wp-content/themes ]; then
  mkdir -p /mnt/efs1/wp-content/themes;
fi

if [ ! -d /mnt/efs1/wp-content/plugins ]; then
  mkdir -p /mnt/efs1/wp-content/plugins;
fi


chmod -R 777 /mnt/efs1/wp-content
chmod -R 777 /mnt/efs1

chown -hR www-data:www-data /var/www/html/*
chown -R www-data:www-data /mnt/efs1/wp-content

exec "$@"
