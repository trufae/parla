# Parla consumes the shared Sailfish GNOME runtime/devel packages.
# Only the app and the pinned Delta Chat JSON-RPC engine are bundled here.
%global vendor_prefix %{_datadir}/%{name}
%global dcrpc_version 2.53.0

%ifarch aarch64
%global dcrpc_arch aarch64
%endif
%ifarch %{arm}
%global dcrpc_arch armv7l
%endif
%ifarch %{ix86}
%global dcrpc_arch i686
%endif

%global debug_package %{nil}

Name:       harbour-parla
Summary:    Delta Chat client
Version:    0.9.2
# Upgrade existing 0.9.2-1 packages that bundled a private GTK runtime.
Release:    2
License:    GPLv3+
URL:        https://github.com/trufae/parla
Source0:    %{name}-%{version}.tar.bz2
Source1:    deltachat-rpc-server-%{dcrpc_arch}-linux

BuildRequires: meson
BuildRequires: ninja
BuildRequires: vala
BuildRequires: gcc
BuildRequires: ccache
BuildRequires: python3-base
BuildRequires: gettext-devel
BuildRequires: librsvg-tools
BuildRequires: json-glib-devel
BuildRequires: sailfish-gnome-devel >= 0.1.0
Requires: sailfish-gnome >= 0.1.0

# SVG rendering at runtime comes from the system gdk-pixbuf loader.
Requires: librsvg

%description
Parla is a native Vala + GTK4 + libadwaita client for Delta Chat:
decentralized, encrypted chat over email. This package uses the shared
sailfish-gnome GTK4/libadwaita runtime and bundles the Delta Chat JSON-RPC
engine. It needs Sailfish OS 5.1 or newer for compositor xdg-shell support.
%if 0%{?_chum}
Title: Parla
Type: desktop-application
DeveloperName: trufae
Categories:
 - Network
 - InstantMessaging
Custom:
  Repo: https://github.com/trufae/parla
Url:
  Homepage: https://github.com/trufae/parla
  Bugtracker: https://github.com/trufae/parla/issues
%endif

%prep
%setup -q -n %{name}-%{version}

%build
rm -rf _build
PREFIX=%{vendor_prefix} sh dist/sailfishos/build-app.sh

%install
DESTDIR=%{buildroot} meson install --no-rebuild -C _build

install -D -m 0755 %{SOURCE1} \
    %{buildroot}%{vendor_prefix}/bin/deltachat-rpc-server
install -D -m 0755 dist/sailfishos/harbour-parla.sh \
    %{buildroot}%{_bindir}/harbour-parla
install -D -m 0644 dist/sailfishos/harbour-parla.desktop \
    %{buildroot}%{_datadir}/applications/harbour-parla.desktop

for size in 86 108 128 172; do
    mkdir -p %{buildroot}%{_datadir}/icons/hicolor/${size}x${size}/apps
    rsvg-convert -w $size -h $size -o \
        %{buildroot}%{_datadir}/icons/hicolor/${size}x${size}/apps/%{name}.png \
        parla.svg
done

%files
%{_bindir}/harbour-parla
%{vendor_prefix}
%{_datadir}/applications/harbour-parla.desktop
%{_datadir}/icons/hicolor/*/apps/%{name}.png
