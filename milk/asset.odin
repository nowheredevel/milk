package milk

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"

ASSET_PREFIX :: "assets/"

asset_load_proc :: #type proc(server: ^Asset_Server, path: string)

// # Asset_Server
// A server used to access assets of variable but preregistered types. Stored within the server
// is a dynamic array of Asset_Storage(s), which internally keep track of the assets loaded. To
// access an asset, use `asset_get` and pass either an Asset_Handle (which is usually found within
// component types), or the direct server and a filepath, along with the type of the desired asset.
Asset_Server :: struct {
    type_map: map[typeid]int,
    storages: [dynamic]Asset_Storage,
    load_procs: [dynamic]asset_load_proc,
    ctx: ^Context,
}

asset_server_new :: proc(ctx: ^Context) -> (out: Asset_Server) {
    out.type_map = {}
    out.storages = make([dynamic]Asset_Storage)
    out.load_procs = make([dynamic]asset_load_proc)
    out.ctx = ctx

    return
}

asset_server_destroy :: proc(server: ^Asset_Server) {
    delete_map(server.type_map)

    for &storage in server.storages {
        asset_storage_destroy(&storage)
    }

    delete(server.storages)
    delete(server.load_procs)
}

asset_server_register_type :: proc(server: ^Asset_Server, $T: typeid, load_proc: asset_load_proc) {
    id := typeid_of(T)
    if id in server.type_map {
        // Type already is registered, return
        return
    }

    append(&server.storages, asset_storage_new(T))
    server.type_map[id] = len(server.storages) - 1
    append(&server.load_procs, load_proc)
}

// # Asset_Handle
// A handle to an asset of an unknown type, via a pointer to its server and its filepath.
// When this handle is actually used, the data given is of the correct type at the path.
Asset_Handle :: struct {
    server: ^Asset_Server,
    path: string,
    id: typeid,
}

// Creates a new Asset Handle by validating that the desired data exists and returning the
// handle.
asset_get_handle :: proc(server: ^Asset_Server, path: string, $T: typeid) -> Asset_Handle {
    if !asset_exists(server, path, T) {
        asset_get(server, path, T)
    }

    return {
        server = server,
        path = path,
        id = typeid_of(T)
    }
}

Asset_Type :: enum {
    Dependent,
    File,
}

@(private)
Asset_Internal_Type :: union {
    Asset_Dependent,
    Asset_File
}

Asset_Dependent :: struct {
    dependencies: [dynamic]Asset_Handle,
}

Asset_File :: struct {
    last_time: os.File_Time,
    full_path: string,
    id: typeid,
}

// TODO: Implement hot-reloading
Asset_Tracker :: struct {
    index: int,
    mutex: sync.Mutex,
    type: Asset_Internal_Type,
    id: typeid,
}

_asset_reload :: proc(server: ^Asset_Server, tracker: ^Asset_Tracker) {
    sync.mutex_lock(&tracker.mutex)

    switch type in tracker.type {
        case Asset_Dependent: {

        }
        case Asset_File: {
            server.load_procs[server.type_map[tracker.id]](server, asset_get_full_path(server.storages[server.type_map[tracker.id]].index_map[tracker.index]))
        }
    }

    sync.mutex_unlock(&tracker.mutex)
}

// # Asset_Storage
// Stores loaded assets of a given type, although this type is not known to the storage until a
// procedure is called. Assets should not be accessed using the storage directly, instead you'll
// want to use `asset_get` which operates on the overarching server.
Asset_Storage :: struct {
    data: rawptr,
    length: int,
    elem_size: int,
    cap: int,
    id: typeid,
    path_map: map[string]Asset_Tracker,
    index_map: [dynamic]string,
}

asset_storage_new :: proc($T: typeid) -> (out: Asset_Storage) {
    out.data = make_multi_pointer([^]T, 8)
    out.length = 0
    out.elem_size = size_of(T)
    out.cap = 8
    out.id = typeid_of(T)
    out.path_map = {}
    out.index_map = make([dynamic]string)
    return
}

asset_storage_destroy :: proc(storage: ^Asset_Storage) {
    free(storage.data)
    delete(storage.path_map)
    delete(storage.index_map)
}

asset_storage_add :: proc(storage: ^Asset_Storage, path: string, data: $T) {
    if path in storage.path_map {
        // Data already exists, just update the data at the path instead.
        asset_storage_update(storage, path, data)
    }
    
    last_time, err := os.last_write_time_by_name(asset_get_full_path(path))

    if err != nil {
        fmt.println(err)
        panic("Error: failed to get last write time!")
    }

    index := storage.length
    tracker := storage.path_map[path]
    tracker.index = index
    tracker.id = storage.id
    storage.path_map[path] = tracker

    if index == storage.cap {
        // About to expand past the cap, time to resize
        error: mem.Allocator_Error
        storage.data, error = mem.resize(storage.data, storage.elem_size * storage.cap, storage.elem_size * (storage.cap * 2))
        storage.cap *= 2
    }

    storage.length += 1

    d := cast([^]T)storage.data
    d[index] = data
    append(&storage.index_map, path)
}

asset_storage_update :: proc(storage: ^Asset_Storage, path: string, data: $T) {
    if path not_in storage.path_map {
        // Data doesn't exist, we need to add it
        asset_storage_add(storage, path, data)
    }

    d := cast([^]T)storage.data
    d[storage.path_map[path].index] = data
}

asset_storage_get :: proc(storage: ^Asset_Storage, path: string, $T: typeid, loc := #caller_location) -> T {
    if path not_in storage.path_map {
        // We should have already loaded the asset
        panic("Asset is not loaded!", loc = loc)
    }

    d := cast([^]T)storage.data
    return d[storage.path_map[path].index]
}

asset_storage_remove :: proc(storage: ^Asset_Storage, path: string, $T: typeid) {
    if path not_in storage.path_map {
        // Asset doesn't exist, return
        fmt.println("Warning: Tried to remove nonexistent asset:", path)
        return
    }

    old_index := storage.path_map[path].index
    end_index := storage.length - 1
    new_asset := storage.index_map[end_index]
    d := cast([^]T)storage.data

    // Remove old asset from storage and copy asset over
    d[old_index] = d[end_index]
    storage.length -= 1

    unordered_remove(&storage.index_map, old_index)
    storage.path_map[new_asset] = old_index
    delete_key(&storage.path_map, path)
}

asset_get :: proc {
    asset_get_from_handle,
    asset_get_from_path,
}

asset_get_from_handle :: proc(handle: ^Asset_Handle, $T: typeid, loc := #caller_location) -> T {
    return asset_get_from_path(handle.server, handle.path, T, loc)
}

asset_get_from_path :: proc(server: ^Asset_Server, path: string, $T: typeid, loc := #caller_location) -> T {
    id := typeid_of(T)

    if id not_in server.type_map {
        panic("Error, asset types must be registered before use!", loc = loc)
    }

    storage := &server.storages[server.type_map[id]]
    outer: if path not_in storage.path_map {
        storage.path_map[path] = {}
        tracker := &storage.path_map[path]
        // Load the asset
        for !sync.mutex_try_lock(&tracker.mutex) {
            if path in storage.path_map {
                break outer
            }
        }

        server.load_procs[server.type_map[id]](server, path)

        sync.mutex_unlock(&tracker.mutex)
    }

    return asset_storage_get(storage, path, T, loc)
}

asset_add :: proc(server: ^Asset_Server, path: string, data: $T, loc := #caller_location) {
    id := typeid_of(T)

    if id not_in server.type_map {
        panic("Error, asset types must be registered before use!", loc = loc)
    }

    storage := &server.storages[server.type_map[id]]
    asset_storage_add(storage, path, data)
}

asset_update :: proc(server: ^Asset_Server, path: string, data: $T, loc := #caller_location) {
    id := typeid_of(T)

    if id not_in server.type_map {
        panic("Error, asset types must be registered before use!", loc = loc)
    }

    storage := &server.storages[server.type_map[id]]
    asset_storage_update(storage, path, data)
}

asset_get_full_path :: proc(path: string, allocator := context.temp_allocator) -> (full_path: string) {
    // Find the file.
    path_slice := [?]string { ASSET_PREFIX, path }
    return strings.concatenate(path_slice[:], allocator)
}

asset_exists :: proc(server: ^Asset_Server, path: string, $T: typeid, loc := #caller_location) -> bool {
    id := typeid_of(T)
    if id not_in server.type_map {
        panic("Error, asset types must be registered before use!", loc)
    }

    storage := server.storages[server.type_map[id]]

    if path not_in storage.path_map {
        return false
    }

    return true
}