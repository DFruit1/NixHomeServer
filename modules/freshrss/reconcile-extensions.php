<?php
declare(strict_types=1);

/**
 * Reconciles per-user FreshRSS extension state with the deployment's declared
 * extension policy. Each FreshRSS account enables user-type extensions through
 * its own persisted config.php, so a user created by first-login
 * auto-registration starts with every extension disabled and the reconciler
 * must turn the declared set on idempotently. This only activates the
 * extension; full-text extraction stays opt-in per feed through the
 * extension's own configuration page.
 */

const DECLARED_EXTENSIONS = ['Af_Readability'];

$dataPath = getenv('FRESHRSS_DATA_PATH');
if (!is_string($dataPath) || $dataPath === '') {
	fwrite(STDERR, "FRESHRSS_DATA_PATH is required\n");
	exit(1);
}

$usernamePattern = getenv('FRESHRSS_USERNAME_PATTERN');
if (!is_string($usernamePattern) || $usernamePattern === '') {
	fwrite(STDERR, "FRESHRSS_USERNAME_PATTERN is required\n");
	exit(1);
}
// The pattern arrives in POSIX-style ^...$ form for bash; PHP needs explicit
// delimiters, and the D modifier stops a trailing newline from matching $.
$pattern = '/' . str_replace('/', '\/', $usernamePattern) . '/D';

$usersPath = $dataPath . '/users';
if (!is_dir($usersPath)) {
	fwrite(STDERR, "FreshRSS users directory does not exist\n");
	exit(1);
}

$entries = scandir($usersPath);
if ($entries === false) {
	fwrite(STDERR, "Could not list the FreshRSS users directory\n");
	exit(1);
}

$reconciled = 0;
foreach ($entries as $entry) {
	if ($entry === '.' || $entry === '..') {
		continue;
	}

	$userPath = $usersPath . '/' . $entry;
	if (!is_dir($userPath) || preg_match($pattern, $entry) !== 1) {
		continue;
	}

	$configPath = $userPath . '/config.php';
	if (!is_file($configPath)) {
		continue;
	}

	try {
		$config = require $configPath;
	} catch (\Throwable $loadError) {
		fwrite(STDERR, "FreshRSS user configuration for {$entry} could not be loaded: {$loadError->getMessage()}\n");
		continue;
	}
	if (!is_array($config)) {
		fwrite(STDERR, "FreshRSS user configuration for {$entry} did not return an array\n");
		continue;
	}

	$extensionsEnabled = $config['extensions_enabled'] ?? [];
	if (!is_array($extensionsEnabled)) {
		$extensionsEnabled = [];
	}

	$dirty = false;
	foreach (DECLARED_EXTENSIONS as $extensionName) {
		if (($extensionsEnabled[$extensionName] ?? null) !== true) {
			$extensionsEnabled[$extensionName] = true;
			$dirty = true;
		}
	}

	if (!$dirty) {
		continue;
	}

	$config['extensions_enabled'] = $extensionsEnabled;

	$temporaryPath = $configPath . '.nixhomeserver.tmp';
	$rendered = "<?php\nreturn " . var_export($config, true) . ";\n";
	if (file_put_contents($temporaryPath, $rendered, LOCK_EX) === false) {
		@unlink($temporaryPath);
		fwrite(STDERR, "Could not write the reconciled FreshRSS configuration for {$entry}\n");
		exit(1);
	}

	$mode = fileperms($configPath);
	if (is_int($mode) && !chmod($temporaryPath, $mode & 0777)) {
		@unlink($temporaryPath);
		fwrite(STDERR, "Could not preserve FreshRSS configuration permissions for {$entry}\n");
		exit(1);
	}

	if (!rename($temporaryPath, $configPath)) {
		@unlink($temporaryPath);
		fwrite(STDERR, "Could not publish the reconciled FreshRSS configuration for {$entry}\n");
		exit(1);
	}

	$reconciled += 1;
}

fwrite(STDERR, "Reconciled FreshRSS extension state for {$reconciled} user(s)\n");
