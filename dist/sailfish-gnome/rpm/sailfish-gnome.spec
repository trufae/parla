# Shared GTK4 stack for Sailfish OS. System libraries remain SDK dependencies.
%global graphene_version 1.10.8
%global epoxy_version 1.5.10
%global gtk_version 4.14.5
%global adw_version 1.5.8
%global xmlb_version 0.3.22
%global appstream_version 1.0.3
%global libsass_version 3.6.5+20231221
%global sassc_version 3.6.1+20201027
%global webp_loader_version 0.2.7
%global debug_package %{nil}

Name:       sailfish-gnome
Summary:    Shared GTK4 and libadwaita runtime for Sailfish OS
Version:    0.1.0
Release:    1.sfos5.1.0.11
License:    LGPL-2.0-or-later AND LGPL-2.1-or-later AND MIT
URL:        https://github.com/trufae/sailfish-gnome
Source0:    %{name}-%{version}.tar.gz
Source1:    graphene-%{graphene_version}.tar.xz
Source2:    libepoxy-%{epoxy_version}.tar.xz
Source3:    gtk-%{gtk_version}.tar.xz
Source4:    libadwaita-%{adw_version}.tar.xz
Source5:    libxmlb_%{xmlb_version}.orig.tar.gz
Source6:    AppStream-%{appstream_version}.tar.xz
Source7:    libsass_%{libsass_version}.orig.tar.xz
Source8:    sassc_%{sassc_version}.orig.tar.xz
Source9:    webp-pixbuf-loader_%{webp_loader_version}.orig.tar.gz

BuildRequires: meson
BuildRequires: ninja
BuildRequires: gcc
BuildRequires: gcc-c++
BuildRequires: ccache
BuildRequires: autoconf
BuildRequires: automake
BuildRequires: libtool
BuildRequires: gperf
BuildRequires: python3-base
BuildRequires: gettext-devel
BuildRequires: glib2-devel >= 2.86
BuildRequires: cairo-devel
BuildRequires: cairo-gobject-devel
BuildRequires: pango-devel
BuildRequires: harfbuzz-devel
BuildRequires: gdk-pixbuf-devel
BuildRequires: fribidi-devel
BuildRequires: json-glib-devel
BuildRequires: wayland-devel
BuildRequires: wayland-protocols-devel
BuildRequires: wayland-egl-devel
BuildRequires: libxkbcommon-devel
BuildRequires: mesa-llvmpipe-libEGL-devel
BuildRequires: mesa-llvmpipe-libGLESv2-devel
BuildRequires: freetype-devel
BuildRequires: fontconfig-devel
BuildRequires: libpng-devel
BuildRequires: libjpeg-turbo-devel
BuildRequires: libtiff-devel
BuildRequires: libxml2-devel
BuildRequires: libyaml-devel
BuildRequires: libcurl-devel
BuildRequires: libwebp-devel
Requires: sailfish-version >= 5.1.0
Requires: glib2 >= 2.86
Requires: librsvg

%description
Wayland GTK4, libadwaita, Graphene, libepoxy, AppStream, libxmlb and the
WebP GdkPixbuf loader for Sailfish OS. Libraries install in the standard
system paths and can be shared by multiple apps. Built for Sailfish OS
5.1.0.11; this is not a complete GNOME desktop or a WebKitGTK port.

%package devel
Summary:    Headers, pkg-config files and Vala bindings for Sailfish GNOME
Requires: %{name} = %{version}-%{release}
Requires: glib2-devel
Requires: cairo-devel
Requires: cairo-gobject-devel
Requires: pango-devel
Requires: harfbuzz-devel
Requires: gdk-pixbuf-devel
Requires: fribidi-devel
Requires: json-glib-devel
Requires: wayland-devel
Requires: wayland-protocols-devel
Requires: wayland-egl-devel
Requires: libxkbcommon-devel
Requires: mesa-llvmpipe-libEGL-devel
Requires: mesa-llvmpipe-libGLESv2-devel
Requires: fontconfig-devel
Requires: freetype-devel
Requires: libxml2-devel
Requires: libyaml-devel
Requires: libcurl-devel

%description devel
Development files for the matching sailfish-gnome runtime. Install in a
Sailfish SDK target to compile GTK4 and libadwaita apps without rebuilding
their dependencies. Includes libadwaita's Vala bindings; introspection
typelibs and Python bindings are not included.

%prep
%setup -q

%build
# mb2 builds the working tree without running %%prep.
rm -rf vendor _stage third-party-licenses
mkdir -p vendor third-party-licenses
for src in %{SOURCE1} %{SOURCE2} %{SOURCE3} %{SOURCE4} %{SOURCE5} \
           %{SOURCE6} %{SOURCE7} %{SOURCE8} %{SOURCE9}; do
    tar xf "$src" -C vendor
done
for module in vendor/*; do
    dest=third-party-licenses/$(basename "$module")
    mkdir -p "$dest"
    find "$module" -maxdepth 1 -type f \
        \( -iname 'copying*' -o -iname 'license*' -o -iname 'notice*' \) \
        -exec cp '{}' "$dest/" \;
done
export GRAPHENE_VERSION=%{graphene_version}
export EPOXY_VERSION=%{epoxy_version}
export GTK_VERSION=%{gtk_version}
export ADW_VERSION=%{adw_version}
export XMLB_VERSION=%{xmlb_version}
export APPSTREAM_VERSION=%{appstream_version}
export LIBSASS_VERSION=%{libsass_version}
export SASSC_VERSION=%{sassc_version}
export WEBP_LOADER_VERSION=%{webp_loader_version}
PREFIX=%{_prefix} LIBDIR=%{_lib} STAGE=$PWD/_stage sh scripts/build-stack.sh

%install
# Sass and the temporary documentation tools stay in _stage, never in the RPM.
for module in graphene-%{graphene_version} libepoxy-%{epoxy_version} \
              libxmlb-%{xmlb_version} gtk-%{gtk_version} \
              AppStream-%{appstream_version} libadwaita-%{adw_version} \
              webp-pixbuf-loader-%{webp_loader_version}; do
    DESTDIR=%{buildroot} meson install --no-rebuild -C vendor/$module/_build
done
install -D -m 0644 vapi/libadwaita-1.vapi %{buildroot}%{_datadir}/vala/vapi/libadwaita-1.vapi
install -D -m 0644 vapi/libadwaita-1.deps %{buildroot}%{_datadir}/vala/vapi/libadwaita-1.deps
mkdir -p %{buildroot}%{_datadir}/aclocal %{buildroot}%{_libexecdir}
rm -rf %{buildroot}%{_datadir}/installed-tests %{buildroot}%{_datadir}/man \
       %{buildroot}%{_datadir}/doc

%post
/sbin/ldconfig
glib-compile-schemas %{_datadir}/glib-2.0/schemas || :
gdk-pixbuf-query-loaders --update-cache || :

%postun
/sbin/ldconfig
glib-compile-schemas %{_datadir}/glib-2.0/schemas || :
gdk-pixbuf-query-loaders --update-cache || :

%files
%license third-party-licenses
%{_bindir}/*
%{_libdir}/*
%exclude %{_libdir}/pkgconfig
%exclude %{_libdir}/*.so
%{_libexecdir}
%{_datadir}/*
%exclude %{_datadir}/vala
%exclude %{_datadir}/aclocal

%files devel
%{_includedir}/*
%{_libdir}/*.so
%{_libdir}/pkgconfig
%{_datadir}/vala
%{_datadir}/aclocal
