#!/usr/bin/env perl

use strict;
use warnings;
use 5.014;
use utf8;

use List::MoreUtils qw(firstidx);
use Mojolicious::Lite;
use Mojolicious::Static;
use File::Slurp qw(read_dir slurp);

our $VERSION = '0.00';
my $prefix = $ENV{EFS_PREFIX} // '/home/derf/lib';
my $hwdb   = $ENV{HWDB_PATH} // '/home/derf/packages/hardware/var/db';
my $listen = $ENV{DWEB_LISTEN} // 'http://127.0.0.1:8099';

sub serve_efs {
	my $self = shift;
	my $path = $self->stash('path') || q{.};

	my ($dir, $file) = ( $path =~ m{ ^ (.+) / ([^/]+) \. html $ }ox );

	if ($path =~ m{ \. html $ }ox) {

		my @all_files = read_dir("${prefix}/${dir}");
		@all_files = grep { -f "${prefix}/${dir}/$_" } sort @all_files;
		my $idx = firstidx { $_ eq $file } @all_files;

		my $prev_idx = ($idx == 0 ? 0 : $idx - 1);
		my $next_idx = ($idx == $#all_files ? $idx : $idx + 1);

		$self->render('efs-main',
			prev => $all_files[$prev_idx],
			next => $all_files[$next_idx],
			randomlink => $all_files[int(rand($#all_files))],
			prevlink => $all_files[$prev_idx] . '.html',
			nextlink => $all_files[$next_idx] . '.html',
			randomlink => $all_files[int(rand($#all_files))] . '.html',
			parentlink => $dir,
			file => $file,
		);
	}
	elsif (-d "${prefix}/${path}") {
		$path =~ s{ / $ }{}ox;
		my @all_files = read_dir("${prefix}/${path}", keep_dot_dot => 1);
		@all_files = map { [$_, -d "${prefix}/${path}/$_" ? "/efs/${path}/$_" : "/efs/${path}/$_.html"] } sort @all_files;
		$self->render('efs-list',
			files => \@all_files,
		);
	}
	else {
		$self->render_static($path);
	}

}

get '/efs/' => \&serve_efs;
get '/efs/*path' => \&serve_efs;

app->config(
	hypnotoad => {
		listen          => [$listen],
		pid_file        => '/tmp/derf_web.pid',
		workers         => 1,
	},
);

app->defaults( layout => 'default' );
push(@{app->static->paths}, $prefix);

app->start();
