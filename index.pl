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
my $prefix = '/home/derf/lib';

sub serve_ithumb {
	my $self = shift;
	my $path = $self->stash('path') || q{.};

	my ($dir, $file) = ( $path =~ m{ ^ (.+) / ([^/]+) \. html $ }ox );

	if ($path =~ m{ \. html $ }ox) {

		my @all_files = read_dir("${prefix}/${dir}");
		@all_files = grep { -f "${prefix}/${dir}/$_" } sort @all_files;
		my $idx = firstidx { $_ eq $file } @all_files;

		my $prev_idx = ($idx == 0 ? 0 : $idx - 1);
		my $next_idx = ($idx == $#all_files ? $idx : $idx + 1);

		$self->render('main',
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
		@all_files = map { [$_, -d "${prefix}/${path}/$_" ? "/${path}/$_" : "/${path}/$_.html"] } sort @all_files;
		$self->render('list',
			files => \@all_files,
		);
	}
	else {
		$self->render_static($path);
	}

}

get '/' => \&serve_ithumb;
get '/*path' => \&serve_ithumb;

app->config(
	hypnotoad => {
		listen          => ['http://127.0.0.1:8099'],
		pid_file        => '/tmp/ithumb.pid',
		workers         => 1,
	},
);

app->defaults( layout => 'default' );
push(@{app->static->paths}, $prefix);

app->start();
