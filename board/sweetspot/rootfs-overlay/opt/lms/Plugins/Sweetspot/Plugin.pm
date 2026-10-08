package Plugins::Sweetspot::Plugin;

# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - collegamento tra Lyrion Music Server e il sistema Sweetspot.
# Comandi (porta CLI 9090 o JSON-RPC):
#
#   sweetspot plugin-stato                 plugin installati e operazioni in corso
#   sweetspot plugin-installa nome:NOME    scarica NOME dal repository dei plugin
#   sweetspot plugin-rimuovi nome:NOME     lo toglie
#
# Installazione e rimozione diventano effettive al riavvio di Lyrion, come
# dalla pagina dei plugin di Lyrion; le impostazioni di Sweetspot lo
# riavviano da sole quando gli scaricamenti sono finiti.

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Utils::ExtensionsManager;
use Slim::Utils::Log;
use Slim::Utils::PluginDownloader;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.sweetspot',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_SWEETSPOT',
});

# Plugin preinstallati da Sweetspot nella cartella dei plugin scaricati.
my @PREINSTALLED = qw(MaterialSkin);

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);

	Slim::Control::Request::addDispatch(['sweetspot', '_cmd'], [0, 0, 1, \&_cli]);

	# Restano nell'elenco dei plugin voluti: cosi' gli aggiornamenti dal
	# repository li aggiornano invece di considerarli da rimuovere.
	my $plugins = Slim::Utils::PluginManager->allPlugins;
	for my $name (@PREINSTALLED) {
		my $p = $plugins->{$name} or next;
		Slim::Utils::ExtensionsManager->enablePlugin($name) if ($p->{basedir} || '') =~ /InstalledPlugins/;
	}
}

sub _cli {
	my $request = shift;

	my $cmd  = $request->getParam('_cmd') || '';
	my $name = $request->getParam('nome') || '';

	if ($cmd eq 'plugin-stato') {
		my $plugins = Slim::Utils::PluginManager->allPlugins;
		my $states  = preferences('plugin.state');
		my %seen;
		my $i = 0;

		for my $n (sort keys %$plugins) {
			my $p = $plugins->{$n};
			next if ($p->{basedir} || '') !~ /InstalledPlugins/;
			$request->addResultLoop('plugins_loop', $i, 'nome', $n);
			$request->addResultLoop('plugins_loop', $i, 'versione', $p->{version} || '');
			$request->addResultLoop('plugins_loop', $i, 'stato', $states->get($n) || '');
			$request->addResultLoop('plugins_loop', $i, 'errore', Slim::Utils::PluginManager->getErrorString($n) || '');
			$seen{$n} = 1;
			$i++;
		}

		# Scaricati ma non ancora installati (serve un riavvio).
		my $all = $states->all;
		for my $n (sort keys %$all) {
			next if $seen{$n} || $n =~ /^_/ || ($all->{$n} || '') ne 'needs-install';
			$request->addResultLoop('plugins_loop', $i, 'nome', $n);
			$request->addResultLoop('plugins_loop', $i, 'versione', '');
			$request->addResultLoop('plugins_loop', $i, 'stato', 'needs-install');
			$i++;
		}

		$request->addResult('scaricamenti', Slim::Utils::PluginDownloader->downloading || 0);
		$request->addResult('riavvio', Slim::Utils::PluginManager->needsRestart ? 1 : 0);
		$request->setStatusDone();
		return;
	}

	if ($name !~ /^\w{1,64}$/) {
		$request->setStatusBadParams();
		return;
	}

	if ($cmd eq 'plugin-installa') {
		$request->setStatusProcessing();

		Slim::Utils::ExtensionsManager::getAllPluginRepos({
			type => 'plugin',
			cb   => sub {
				my ($data, $err) = @_;
				my @all = @{ $data || [] };
				my ($entry) = grep { $_->{name} eq $name } @all;

				if (!$entry || !$entry->{url} || !$entry->{sha}) {
					$log->warn("plugin $name non trovato nei repository" . ($err ? ": $err" : ''));
					$request->addResult('errore', ($err || !@all)
						? 'elenco dei plugin non raggiungibile'
						: 'plugin non presente nell\'elenco dei plugin');
					$request->setStatusDone();
					return;
				}

				main::INFOLOG && $log->info("installazione di $name $entry->{version} da $entry->{url}");
				Slim::Utils::PluginDownloader->install({ name => $name, url => $entry->{url}, sha => lc($entry->{sha}) });
				Slim::Utils::ExtensionsManager->enablePlugin($name);

				$request->addResult('versione', $entry->{version});
				$request->setStatusDone();
			},
		});
		return;
	}

	if ($cmd eq 'plugin-rimuovi') {
		Slim::Utils::PluginDownloader->uninstall($name);
		Slim::Utils::ExtensionsManager->disablePlugin($name);
		$request->setStatusDone();
		return;
	}

	$request->setStatusBadDispatch();
}

1;
