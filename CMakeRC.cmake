# This block is executed when generating an intermediate resource file, not when
# running in CMake configure mode
if(_CMRC_GENERATE_MODE)
    # Read in the digits
    file(READ "${INPUT_FILE}" bytes HEX)
    # Format each pair into a character literal. Heuristics seem to favor doing
    # the conversion in groups of five for fastest conversion
    string(REGEX REPLACE "(..)(..)(..)(..)(..)" "'\\\\x\\1','\\\\x\\2','\\\\x\\3','\\\\x\\4','\\\\x\\5'," chars "${bytes}")
    # Since we did this in groups, we have some leftovers to clean up
    string(LENGTH "${bytes}" n_bytes2)
    math(EXPR n_bytes "${n_bytes2} / 2")
    math(EXPR remainder "${n_bytes} % 5") # <-- '5' is the grouping count from above
    set(cleanup_re "$")
    set(cleanup_sub )
    while(remainder)
        set(cleanup_re "(..)${cleanup_re}")
        set(cleanup_sub "'\\\\x\\${remainder}',${cleanup_sub}")
        math(EXPR remainder "${remainder} - 1")
    endwhile()
    if(NOT cleanup_re STREQUAL "$")
        string(REGEX REPLACE "${cleanup_re}" "${cleanup_sub}" chars "${chars}")
    endif()
    string(CONFIGURE [[
        namespace { const char file_array[] = { @chars@ 0 }; }
        namespace cmrc { namespace @NAMESPACE@ { namespace res_chars {
        extern const char* const @SYMBOL@_begin = file_array;
        extern const char* const @SYMBOL@_end = file_array + @n_bytes@;
        }}}
    ]] code)
    file(WRITE "${OUTPUT_FILE}" "${code}")
    # Exit from the script. Nothing else needs to be processed
    return()
endif()

set(_version 2.0.0)

cmake_minimum_required(VERSION 3.3)
include(CMakeParseArguments)

if(COMMAND cmrc_add_resource_library)
    if(NOT DEFINED _CMRC_VERSION OR NOT (_version STREQUAL _CMRC_VERSION))
        message(WARNING "More than one CMakeRC version has been included in this project.")
    endif()
    # CMakeRC has already been included! Don't do anything
    return()
endif()

set(_CMRC_VERSION "${_version}" CACHE INTERNAL "CMakeRC version. Used for checking for conflicts")

set(_CMRC_SCRIPT "${CMAKE_CURRENT_LIST_FILE}" CACHE INTERNAL "Path to CMakeRC script")

function(_cmrc_normalize_path var)
    set(path "${${var}}")
    file(TO_CMAKE_PATH "${path}" path)
    while(path MATCHES "//")
        string(REPLACE "//" "/" path "${path}")
    endwhile()
    string(REGEX REPLACE "/+$" "" path "${path}")
    set("${var}" "${path}" PARENT_SCOPE)
endfunction()

get_filename_component(_inc_dir "${CMAKE_BINARY_DIR}/_cmrc/include" ABSOLUTE)
set(CMRC_INCLUDE_DIR "${_inc_dir}" CACHE INTERNAL "Directory for CMakeRC include files")
# Let's generate the primary include file
file(MAKE_DIRECTORY "${CMRC_INCLUDE_DIR}/cmrc")
set(hpp_content [==[
#pragma once

#include <cassert>
#include <iterator>
#include <list>
#include <map>
#include <string>
#include <type_traits>
#include <string_view>

#define CMRC_DECLARE(libid) \
namespace cmrc \
{ \
    namespace detail \
    { \
        struct dummy; \
        static_assert(std::is_same<dummy, ::cmrc::detail::dummy>::value, "CMRC_DECLARE() must only appear at the global namespace"); \
    } \
    namespace libid \
    { \
        [[nodiscard]] cmrc::embedded_filesystem get_filesystem(void) noexcept; \
    } \
} \
static_assert(true)

namespace cmrc
{
    class embedded_filesystem;
    class file;
    class directory_entry;

    namespace detail
    {
        struct dummy;
        class directory;
        struct file_data;
        class file_or_directory;
        struct created_subdirectory;

        /** @brief Split path */
        [[nodiscard]] std::pair<std::string, std::string> splitPath(const std::string_view &path) noexcept;

        /** @brief Normalize path */
        [[nodiscard]] std::string normalizePath(const std::string_view &path) noexcept;
    }
}

class cmrc::file
{
public:
    using iterator = const char*;
    using const_iterator = iterator;

    /** @brief Default constructor */
    file(void) noexcept = default;

    /** @brief Data constructor */
    file(const iterator beg, const iterator end) noexcept : _begin(beg), _end(end) {}

    /** @brief Begin / End iterators */
    [[nodiscard]] iterator begin(void) const noexcept { return _begin; }
    [[nodiscard]] iterator cbegin(void) const noexcept { return _begin; }
    [[nodiscard]] iterator end(void) const noexcept { return _end; }
    [[nodiscard]] iterator cend(void) const noexcept { return _end; }

    /** @brief File size */
    [[nodiscard]] std::size_t size(void) const { return static_cast<std::size_t>(std::distance(begin(), end())); }

private:
    const char* _begin { nullptr };
    const char* _end { nullptr };
};

class cmrc::detail::file_or_directory
{
public:
    /** @brief File constructor */
    explicit file_or_directory(const file_data &f) : _isFile(true) { _data.file_data = &f; }

    /** @brief Directory constructor */
    explicit file_or_directory(const directory &d) : _isFile(false) { _data.directory = &d; }


    /** @brief Check if entry is a file */
    [[nodiscard]] bool is_file(void) const noexcept { return _isFile; }

    /** @brief Check if entry is a directory */
    [[nodiscard]] bool is_directory(void) const noexcept { return !is_file(); }


    /** @brief Get underlying directory */
    [[nodiscard]] const directory &as_directory(void) const noexcept
    {
        assert(!is_file());
        return *_data.directory;
    }

    /** @brief Get underlying file */
    [[nodiscard]] const file_data &as_file(void) const noexcept
    {
        assert(is_file());
        return *_data.file_data;
    }

private:
    union _data_t
    {
        const file_data *file_data;
        const directory *directory;
    } _data;
    bool _isFile {};
};

struct cmrc::detail::file_data
{
    const char *from;
    const char *to;

    /** @brief Deleted copy constructor */
    file_data(const file_data&) = delete;

    /** @brief Data constructor */
    file_data(const char * const b, const char * const e) : from(b), to(e) {}
};

struct cmrc::detail::created_subdirectory
{
    directory &directory;
    file_or_directory &index_entry;
};

class cmrc::detail::directory
{
public:
    /** @brief Default constructor */
    directory(void) noexcept = default;

   /** @brief Deleted copy constructor */
    directory(const directory &) noexcept = delete;


    /** @brief Add subdirectory */
    [[nodiscard]] created_subdirectory add_subdir(const std::string_view &name) noexcept
    {
        _dirs.emplace_back();
        auto &back = _dirs.back();
        auto &fod = _index.emplace(name, file_or_directory{back}).first->second;
        return created_subdirectory { back, fod };
    }

    /** @brief Add file */
    [[nodiscard]] file_or_directory *add_file(const std::string_view &name, const char * const begin, const char * const end) noexcept
    {
        assert(_index.find(name) == _index.end());
        _files.emplace_back(begin, end);
        return &_index.emplace(name, file_or_directory{_files.back()}).first->second;
    }

    /** @brief Get entry */
    [[nodiscard]] const file_or_directory *get(const std::string_view &path) const noexcept
    {
        auto pair = splitPath(path);
        auto child = _index.find(pair.first);
        if (child == _index.end()) {
            return nullptr;
        }
        auto& entry  = child->second;
        if (pair.second.empty()) {
            // We're at the end of the path
            return &entry;
        }

        if (entry.is_file()) {
            // We can't traverse into a file. Stop.
            return nullptr;
        }
        // Keep going down
        return entry.as_directory().get(pair.second);
    }

    class iterator
    {
    public:
        using base_iterator = std::map<std::string, file_or_directory>::const_iterator;
        using value_type = directory_entry;
        using difference_type = std::ptrdiff_t;
        using pointer = const value_type*;
        using reference = const value_type&;
        using iterator_category = std::input_iterator_tag;

        /** @brief Default constructor */
        iterator(void) noexcept = default;

        /** @brief Range constructor */
        explicit iterator(const base_iterator from, const base_iterator to) noexcept
            : _from(from), _to(to) {}

        /** @brief Begin / end iterators */
        [[nodiscard]] iterator begin(void) const noexcept { return *this; }
        [[nodiscard]] iterator end(void) const noexcept { return iterator(_to, _to); }

        /** @brief Dereference operator */
        [[nodiscard]] inline value_type operator*(void) const noexcept;

        /** @brief Comparison operator */
        [[nodiscard]] bool operator==(const iterator& rhs) const noexcept { return _from == rhs._from; }
        [[nodiscard]] bool operator!=(const iterator& rhs) const noexcept { return !(*this == rhs); }

        /** @brief Postfix increment operator */
        [[nodiscard]] iterator operator++(void) noexcept
        {
            auto cp = *this;
            ++_from;
            return cp;
        }

        /** @brief Prefix increment operator */
        [[nodiscard]] iterator &operator++(int) noexcept
        {
            ++_from;
            return *this;
        }

    private:
        base_iterator _from;
        base_iterator _to;
    };

    using const_iterator = iterator;

    /** @brief Begin / end iterators */
    [[nodiscard]] iterator begin(void) const noexcept { return iterator(_index.begin(), _index.end()); }
    [[nodiscard]] iterator end(void) const noexcept { return iterator(); }

private:
    std::list<file_data> _files;
    std::list<directory> _dirs;
    std::map<std::string, file_or_directory, std::less<>> _index;
};

class cmrc::directory_entry
{
public:
    /** @brief Directory constructor */
    explicit directory_entry(const std::string_view &filename, const detail::file_or_directory &item) noexcept
        : _fname(filename), _item(&item) {}

    /** @brief Get file name */
    [[nodiscard]] std::string_view filename(void) const noexcept { return _fname; }

    /** @brief Check if entry is a file */
    [[nodiscard]] bool is_file(void) const noexcept { return _item->is_file(); }

    /** @brief Check if entry is a directory */
    [[nodiscard]] bool is_directory(void) const noexcept { return _item->is_directory(); }

private:
    std::string _fname;
    const detail::file_or_directory *_item;
};

inline cmrc::detail::directory::iterator::value_type cmrc::detail::directory::iterator::operator*(void) const noexcept
{
    assert(begin() != end());
    return directory_entry(_from->first, _from->second);
}

namespace cmrc
{
    /** @brief Directory iterator */
    using directory_iterator = detail::directory::iterator;

    namespace detail
    {
        /** @brief Index of filesystem */
        using index_type = std::map<std::string, const file_or_directory *>;
    }
}

class cmrc::embedded_filesystem
{
public:
    /** @brief Index constructor */
    explicit embedded_filesystem(const detail::index_type &index) noexcept : _index(&index) {}

    /** @brief Open file from index */
    [[nodiscard]] file open(const std::string_view &path) const noexcept
    {
        auto entry_ptr = getEntry(path);
        if (!entry_ptr || !entry_ptr->is_file()) {
            return file { nullptr, nullptr };
        }
        auto &dat = entry_ptr->as_file();
        return file { dat.from, dat.to };
    }

    /** @brief Check if path is a file */
    [[nodiscard]] bool is_file(const std::string_view &path) const noexcept
    {
        auto entry_ptr = getEntry(path);
        return entry_ptr && entry_ptr->is_file();
    }

    /** @brief Check if path is a directory */
    [[nodiscard]] bool is_directory(const std::string_view &path) const noexcept
    {
        auto entry_ptr = getEntry(path);
        return entry_ptr && entry_ptr->is_directory();
    }

    /** @brief Check if path exists */
    [[nodiscard]] bool exists(const std::string_view &path) const noexcept { return !!getEntry(path); }

    /** @brief Get an iterator over directory at path */
    [[nodiscard]] directory_iterator iterate_directory(const std::string &path) const noexcept
    {
        auto entry_ptr = getEntry(path);
        if (!entry_ptr || !entry_ptr->is_directory())
            return directory_iterator();
        return entry_ptr->as_directory().begin();
    }

private:
    /** @brief Get entry */
    [[nodiscard]] const detail::file_or_directory* getEntry(const std::string_view &path) const noexcept
    {
        const auto normalized = detail::normalizePath(path);
        auto found = _index->find(normalized);
        if (found == _index->end()) {
            return nullptr;
        } else {
            return found->second;
        }
    }

    // Never-null:
    const cmrc::detail::index_type* _index;
};

inline std::pair<std::string, std::string> cmrc::detail::splitPath(const std::string_view &path) noexcept
{
    const auto first_sep = path.find("/");
    if (first_sep == path.npos) {
        return std::make_pair(std::string(path), std::string());
    } else {
        return std::make_pair(std::string(path.substr(0, first_sep)), std::string(path.substr(first_sep + 1)));
    }
}

inline std::string cmrc::detail::normalizePath(const std::string_view &path) noexcept
{
    std::string copy(path);
    while (copy.find("/") == 0) {
        copy.erase(copy.begin());
    }
    while (!copy.empty() && (copy.rfind("/") == copy.size() - 1)) {
        copy.pop_back();
    }
    auto off = copy.npos;
    while ((off = copy.find("//")) != copy.npos) {
        copy.erase(copy.begin() + static_cast<std::string::difference_type>(off));
    }
    return copy;
}
]==])

set(cmrc_hpp "${CMRC_INCLUDE_DIR}/cmrc/cmrc.hpp" CACHE INTERNAL "")
set(_generate 1)
if(EXISTS "${cmrc_hpp}")
    file(READ "${cmrc_hpp}" _current)
    if(_current STREQUAL hpp_content)
        set(_generate 0)
    endif()
endif()
file(GENERATE OUTPUT "${cmrc_hpp}" CONTENT "${hpp_content}" CONDITION ${_generate})

add_library(cmrc-base INTERFACE)
target_include_directories(cmrc-base INTERFACE $<BUILD_INTERFACE:${CMRC_INCLUDE_DIR}>)
# Signal a basic C++11 feature to require C++11.
target_compile_features(cmrc-base INTERFACE cxx_nullptr)
set_property(TARGET cmrc-base PROPERTY INTERFACE_CXX_EXTENSIONS OFF)
add_library(cmrc::base ALIAS cmrc-base)

function(cmrc_add_resource_library name)
    set(args ALIAS NAMESPACE TYPE)
    cmake_parse_arguments(ARG "" "${args}" "" "${ARGN}")
    # Generate the identifier for the resource library's namespace
    set(ns_re "[a-zA-Z_][a-zA-Z0-9_]*")
    if(NOT DEFINED ARG_NAMESPACE)
        # Check that the library name is also a valid namespace
        if(NOT name MATCHES "${ns_re}")
            message(SEND_ERROR "Library name is not a valid namespace. Specify the NAMESPACE argument")
        endif()
        set(ARG_NAMESPACE "${name}")
    else()
        if(NOT ARG_NAMESPACE MATCHES "${ns_re}")
            message(SEND_ERROR "NAMESPACE for ${name} is not a valid C++ namespace identifier (${ARG_NAMESPACE})")
        endif()
    endif()
    set(libname "${name}")
    # Check that type is either "STATIC" or "OBJECT", or default to "STATIC" if
    # not set
    if(NOT DEFINED ARG_TYPE)
        set(ARG_TYPE STATIC)
    elseif(NOT "${ARG_TYPE}" MATCHES "^(STATIC|OBJECT)$")
        message(SEND_ERROR "${ARG_TYPE} is not a valid TYPE (STATIC and OBJECT are acceptable)")
        set(ARG_TYPE STATIC)
    endif()
    # Generate a library with the compiled in character arrays.
    string(CONFIGURE [=[
        #include <cmrc/cmrc.hpp>
        #include <map>
        #include <utility>

        namespace cmrc {
        namespace @ARG_NAMESPACE@ {

        namespace res_chars {
        // These are the files which are available in this resource library
        $<JOIN:$<TARGET_PROPERTY:@libname@,CMRC_EXTERN_DECLS>,
        >
        }

        namespace {

        const cmrc::detail::index_type&
        get_root_index() {
            static cmrc::detail::directory root_directory_;
            static cmrc::detail::file_or_directory root_directory_fod{root_directory_};
            static cmrc::detail::index_type root_index;
            root_index.emplace("", &root_directory_fod);
            struct dir_inl {
                class cmrc::detail::directory& directory;
            };
            dir_inl root_directory_dir{root_directory_};
            (void)root_directory_dir;
            $<JOIN:$<TARGET_PROPERTY:@libname@,CMRC_MAKE_DIRS>,
            >
            $<JOIN:$<TARGET_PROPERTY:@libname@,CMRC_MAKE_FILES>,
            >
            return root_index;
        }

        }

        cmrc::embedded_filesystem get_filesystem() {
            static auto& index = get_root_index();
            return cmrc::embedded_filesystem{index};
        }

        } // @ARG_NAMESPACE@
        } // cmrc
    ]=] cpp_content @ONLY)
    get_filename_component(libdir "${CMAKE_CURRENT_BINARY_DIR}/__cmrc_${name}" ABSOLUTE)
    get_filename_component(lib_tmp_cpp "${libdir}/lib_.cpp" ABSOLUTE)
    string(REPLACE "\n        " "\n" cpp_content "${cpp_content}")
    file(GENERATE OUTPUT "${lib_tmp_cpp}" CONTENT "${cpp_content}")
    get_filename_component(libcpp "${libdir}/lib.cpp" ABSOLUTE)
    add_custom_command(OUTPUT "${libcpp}"
        DEPENDS "${lib_tmp_cpp}" "${cmrc_hpp}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${lib_tmp_cpp}" "${libcpp}"
        COMMENT "Generating ${name} resource loader"
        )
    # Generate the actual static library. Each source file is just a single file
    # with a character array compiled in containing the contents of the
    # corresponding resource file.
    add_library(${name} ${ARG_TYPE} ${libcpp})
    set_property(TARGET ${name} PROPERTY CMRC_LIBDIR "${libdir}")
    set_property(TARGET ${name} PROPERTY CMRC_NAMESPACE "${ARG_NAMESPACE}")
    target_link_libraries(${name} PUBLIC cmrc::base)
    set_property(TARGET ${name} PROPERTY CMRC_IS_RESOURCE_LIBRARY TRUE)
    if(ARG_ALIAS)
        add_library("${ARG_ALIAS}" ALIAS ${name})
    endif()
    cmrc_add_resources(${name} ${ARG_UNPARSED_ARGUMENTS})
endfunction()

function(_cmrc_register_dirs name dirpath)
    if(dirpath STREQUAL "")
        return()
    endif()
    # Skip this dir if we have already registered it
    get_target_property(registered "${name}" _CMRC_REGISTERED_DIRS)
    if(dirpath IN_LIST registered)
        return()
    endif()
    # Register the parent directory first
    get_filename_component(parent "${dirpath}" DIRECTORY)
    if(NOT parent STREQUAL "")
        _cmrc_register_dirs("${name}" "${parent}")
    endif()
    # Now generate the registration
    set_property(TARGET "${name}" APPEND PROPERTY _CMRC_REGISTERED_DIRS "${dirpath}")
    _cm_encode_fpath(sym "${dirpath}")
    if(parent STREQUAL "")
        set(parent_sym root_directory)
    else()
        _cm_encode_fpath(parent_sym "${parent}")
    endif()
    get_filename_component(leaf "${dirpath}" NAME)
    set_property(
        TARGET "${name}"
        APPEND PROPERTY CMRC_MAKE_DIRS
        "static auto ${sym}_dir = ${parent_sym}_dir.directory.add_subdir(\"${leaf}\")\;"
        "root_index.emplace(\"${dirpath}\", &${sym}_dir.index_entry)\;"
        )
endfunction()

function(cmrc_add_resources name)
    get_target_property(is_reslib ${name} CMRC_IS_RESOURCE_LIBRARY)
    if(NOT TARGET ${name} OR NOT is_reslib)
        message(SEND_ERROR "cmrc_add_resources called on target '${name}' which is not an existing resource library")
        return()
    endif()

    set(options)
    set(args WHENCE PREFIX)
    set(list_args)
    cmake_parse_arguments(ARG "${options}" "${args}" "${list_args}" "${ARGN}")

    if(NOT ARG_WHENCE)
        set(ARG_WHENCE ${CMAKE_CURRENT_SOURCE_DIR})
    endif()
    _cmrc_normalize_path(ARG_WHENCE)
    get_filename_component(ARG_WHENCE "${ARG_WHENCE}" ABSOLUTE)

    # Generate the identifier for the resource library's namespace
    get_target_property(lib_ns "${name}" CMRC_NAMESPACE)

    get_target_property(libdir ${name} CMRC_LIBDIR)
    get_target_property(target_dir ${name} SOURCE_DIR)
    file(RELATIVE_PATH reldir "${target_dir}" "${CMAKE_CURRENT_SOURCE_DIR}")
    if(reldir MATCHES "^\\.\\.")
        message(SEND_ERROR "Cannot call cmrc_add_resources in a parent directory from the resource library target")
        return()
    endif()

    foreach(input IN LISTS ARG_UNPARSED_ARGUMENTS)
        _cmrc_normalize_path(input)
        get_filename_component(abs_in "${input}" ABSOLUTE)
        # Generate a filename based on the input filename that we can put in
        # the intermediate directory.
        file(RELATIVE_PATH relpath "${ARG_WHENCE}" "${abs_in}")
        if(relpath MATCHES "^\\.\\.")
            # If relative path contains whence, use it from there
            get_filename_component(WhenceName ${ARG_WHENCE} NAME)
            string(FIND ${relpath} ${WhenceName} relativeIndex)
            if(relativeIndex EQUAL -1)
                # Error on files that exist outside whence subdirectory
                message(SEND_ERROR "Cannot add file '${input}': File must be in a subdirectory of ${ARG_WHENCE}")
                continue()
            else()
                # Allow a file to get picked from build tree if its path contains whence
                string(LENGTH ${WhenceName} whenceSize)
                math(EXPR whenceIndex "${relativeIndex} + ${whenceSize} + 1")
                string(SUBSTRING ${relpath} "${whenceIndex}" "-1" outpath)
                set(relpath "./${outpath}")
            endif()
        endif()
        if(DEFINED ARG_PREFIX)
            _cmrc_normalize_path(ARG_PREFIX)
        endif()
        if(ARG_PREFIX AND NOT ARG_PREFIX MATCHES "/$")
            set(ARG_PREFIX "${ARG_PREFIX}/")
        endif()
        get_filename_component(dirpath "${ARG_PREFIX}${relpath}" DIRECTORY)
        _cmrc_register_dirs("${name}" "${dirpath}")
        get_filename_component(abs_out "${libdir}/intermediate/${relpath}.cpp" ABSOLUTE)
        # Generate a symbol name relpath the file's character array
        _cm_encode_fpath(sym "${relpath}")
        # Get the symbol name for the parent directory
        if(dirpath STREQUAL "")
            set(parent_sym root_directory)
        else()
            _cm_encode_fpath(parent_sym "${dirpath}")
        endif()
        # Generate the rule for the intermediate source file
        _cmrc_generate_intermediate_cpp(${lib_ns} ${sym} "${abs_out}" "${abs_in}")
        target_sources(${name} PRIVATE "${abs_out}")
        set_property(TARGET ${name} APPEND PROPERTY CMRC_EXTERN_DECLS
            "// Pointers to ${input}"
            "extern const char* const ${sym}_begin\;"
            "extern const char* const ${sym}_end\;"
            )
        get_filename_component(leaf "${relpath}" NAME)
        set_property(
            TARGET ${name}
            APPEND PROPERTY CMRC_MAKE_FILES
            "root_index.emplace("
            "    \"${ARG_PREFIX}${relpath}\","
            "    ${parent_sym}_dir.directory.add_file("
            "        \"${leaf}\","
            "        res_chars::${sym}_begin,"
            "        res_chars::${sym}_end"
            "    )"
            ")\;"
            )
    endforeach()
endfunction()

function(_cmrc_generate_intermediate_cpp lib_ns symbol outfile infile)
    add_custom_command(
        # This is the file we will generate
        OUTPUT "${outfile}"
        # These are the primary files that affect the output
        DEPENDS "${infile}" "${_CMRC_SCRIPT}"
        COMMAND
            "${CMAKE_COMMAND}"
                -D_CMRC_GENERATE_MODE=TRUE
                -DNAMESPACE=${lib_ns}
                -DSYMBOL=${symbol}
                "-DINPUT_FILE=${infile}"
                "-DOUTPUT_FILE=${outfile}"
                -P "${_CMRC_SCRIPT}"
        COMMENT "Generating intermediate file for ${infile}"
    )
endfunction()

function(_cm_encode_fpath var fpath)
    string(MAKE_C_IDENTIFIER "${fpath}" ident)
    string(MD5 hash "${fpath}")
    string(SUBSTRING "${hash}" 0 4 hash)
    set(${var} f_${hash}_${ident} PARENT_SCOPE)
endfunction()
