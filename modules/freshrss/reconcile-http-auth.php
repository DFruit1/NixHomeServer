<?php
declare(strict_types=1);

$dataPath = getenv('FRESHRSS_DATA_PATH');
if (!is_string($dataPath) || $dataPath === '') {
	fwrite(STDERR, "FRESHRSS_DATA_PATH is required\n");
	exit(1);
}

$configPath = $dataPath . '/config.php';
if (!is_file($configPath)) {
	fwrite(STDERR, "FreshRSS config.php does not exist\n");
	exit(1);
}

$config = require $configPath;
if (!is_array($config)) {
	fwrite(STDERR, "FreshRSS config.php did not return an array\n");
	exit(1);
}

if (($config['http_auth_auto_register'] ?? null) === true
		&& ($config['http_auth_auto_register_email_field'] ?? null) === '') {
	exit(0);
}

$config['http_auth_auto_register'] = true;
$config['http_auth_auto_register_email_field'] = '';

$temporaryPath = $configPath . '.nixhomeserver.tmp';
$rendered = "<?php\nreturn " . var_export($config, true) . ";\n";
if (file_put_contents($temporaryPath, $rendered, LOCK_EX) === false) {
	@unlink($temporaryPath);
	fwrite(STDERR, "Could not write the reconciled FreshRSS configuration\n");
	exit(1);
}

$mode = fileperms($configPath);
if (is_int($mode) && !chmod($temporaryPath, $mode & 0777)) {
	@unlink($temporaryPath);
	fwrite(STDERR, "Could not preserve FreshRSS config.php permissions\n");
	exit(1);
}

if (!rename($temporaryPath, $configPath)) {
	@unlink($temporaryPath);
	fwrite(STDERR, "Could not publish the reconciled FreshRSS configuration\n");
	exit(1);
}

fwrite(STDERR, "Reconciled FreshRSS HTTP-auth auto-registration\n");
