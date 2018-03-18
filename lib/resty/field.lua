local Validator = require "resty.validator"
local empty_array_mt = require "cjson".empty_array_mt
local cjson_encode = require "cjson.safe".encode
local cjson_decode = require "cjson.safe".decode
local string_format = string.format
local table_concat = table.concat
local table_insert = table.insert
local next = next
local ipairs = ipairs
local setmetatable = setmetatable
local type = type
local rawset = rawset
local ngx_localtime = ngx.localtime
local ngx_time = ngx.time

local version = '1.0'

local function array(t)
    return setmetatable(t or {}, empty_array_mt)
end
local function list(a, b)
    local t = {}
    if a then
        for k, v in ipairs(a) do
            t[#t+1] = v
        end
    end
    if b then
        for k, v in ipairs(b) do
            t[#t+1] = v
        end
    end
    return t
end

local VALIDATE_STAGES = {'client_to_lua','lua_to_db','db_to_lua','lua_to_client'}

local function __call(cls, attrs)
    return cls:new(attrs)
end

local basefield = {}
basefield.__index = basefield
basefield.__call = __call
function basefield.new(cls, attrs)
    local self = setmetatable(attrs, cls)
    self:_check_attributes()
    self.error_messages = self.error_messages or {}
    if self.null == nil then
        self.null = true
    end
    self.db_type = self.db_type or self.type
    self.label = self.label or self[2] or self.name
    if self.default then
        if type(self.default) == 'function' then
            self.get_default = function (self) return self.default() end
        else
            self.get_default = function (self) return self.default end
        end
    end
    if self.validators == nil then
        self.validators = {}
    end
    for i, validate_stage in ipairs(VALIDATE_STAGES) do
        if self[validate_stage] then 
            -- user provide custom function, so skip composing validators 
            -- and just register this function in validators as the only validator
            self.validators[validate_stage] = {self[validate_stage]}
        else
            local user_validators = self.validators[validate_stage] or {}
            self.validators[validate_stage] = {}
            self['_make_native_validators_for_'..validate_stage](self, self.validators[validate_stage])
            self['_compose_validators_for_'..validate_stage](self, user_validators)
        end
    end
    return self            
end
function basefield.get_empty_value_to_update(self)
    return ''
end
local function normalize_choices(c)
    if type(c) == 'function' then
        -- dynamic choices
        return c
    elseif type(c[1]) == nil then
    -- {a = true, b = true} => {{'a', 'a'},{'b','b'}}
    -- {a='foo', b = true, c = 1} => {{'foo', 'a'},{'b','b'},{1,'c'}}
        local nc = array()
        for k, v in pairs(c) do
            if v == true then
                nc[#nc+1] = {k, k}
            else
                nc[#nc+1] = {v, k}
            end
        end
        return nc
    elseif type(c[1]) ~= 'table' then
    -- {'a','b'}  => {{'a', 'a'},{'b','b'}}
        local nc = array()
        for i, v in ipairs(c) do
            nc[i] = {v, tostring(v)}
        end
        return nc      
    else
        -- standard table form
        return array(c)
    end
end
function basefield._check_attributes(self)
    self.name = self.name or self[1] -- for easy defination of name
    assert(self.name, 'you must define `name` for a field')
    if self.choices then
        -- currently only support basic type choices. 
        -- i.e. string and number, not table
        assert(
            type(self.choices)=='table' or 
            type(self.choices)=='function', 
            '`choices` must be a table or function')
        self.choices = normalize_choices(self.choices)
    end
end
function basefield._make_native_validators_for_lua_to_db(self, validators)

end
function basefield._make_native_validators_for_lua_to_client(self, validators)

end
function basefield._make_native_validators_for_db_to_lua(self, validators)
    -- ** null_converter是否适用于postgresql 
    table.insert(validators, 1, Validator.null_converter)
end
function basefield._make_native_validators_for_client_to_lua(self, validators)
    if self.required then
        table.insert(validators, 1, Validator.required{
            name = self.label, 
            message = self.error_messages.required})
    else
        table.insert(validators, 1, Validator.not_required)
    end
    if self.choices then
        -- choices应是最后一个验证环节
        if type(self.choices) == 'function' then
            table.insert(validators, self:_get_dynamic_choices_validator())
        else
            table.insert(validators, self:_get_static_choices_validator())
        end
    end
end
function basefield._get_dynamic_choices_validator(self)
    -- here, model as a runtime env
    return function (value, model)
        local choices = self.choices(model)
        if not choices then
            return value -- **如果没有设定, 默认不需要检验
        end
        if not self:match_choices(choices, value) then
            return nil, '无效选择项'
        else
            return value
        end
    end
end
function basefield._get_static_choices_validator(self)
    local choices = {} 
    local labels = {} 
    for i, v in ipairs(self.choices) do
        choices[v[1]] = true
        labels[#labels+1] = v[2]
    end
    local message = string_format('无效选择项, 请从"%s"之中选择', table_concat(labels, "," )) 
    return function (value)
        if not self:match_choices(choices, value) then
            return nil, message
        else
            return value
        end
    end
end
function basefield.match_choices(self, choices, value)
    return choices[value]
end
-- db_to_lua和client_to_lua是field优先, lua_to_db和lua_to_client是user优先
function basefield._compose_validators_for_db_to_lua(self, user_validators)
    self.validators.db_to_lua = list(self.validators.db_to_lua, user_validators)
    return self:_compose_validators_for_stage('db_to_lua')
end
function basefield._compose_validators_for_client_to_lua(self, user_validators)
    self.validators.client_to_lua = list(self.validators.client_to_lua, user_validators)
    return self:_compose_validators_for_stage('client_to_lua')
end
function basefield._compose_validators_for_lua_to_db(self, user_validators)
    self.validators.lua_to_db = list(user_validators, self.validators.lua_to_db)
    return self:_compose_validators_for_stage('lua_to_db')
end
function basefield._compose_validators_for_lua_to_client(self, user_validators)
    self.validators.lua_to_client = list(user_validators, self.validators.lua_to_client)
    return self:_compose_validators_for_stage('lua_to_client')
end
function basefield._compose_validators_for_stage(self, validate_stage)
    local validators = self.validators[validate_stage]
    local n = #validators
    if n == 0 then
        self[validate_stage] = Validator.as_is
    elseif n == 1 then
        self[validate_stage] = validators[1]
    else     
        local function composed_validator(value, model)
            local err
            for i, validator in ipairs(validators) do
                value, err = validator(value, model)
                if err ~= nil then
                    return nil, err
                elseif value == nil then
                    -- not-required validator, skip the rest validations
                    return
                end
            end
            return value
        end
        self[validate_stage] = composed_validator
    end
end


local string = setmetatable({type='string', db_type='varchar'}, basefield)
string.__index = string
string.__call = __call
function string._check_attributes(self)
    basefield._check_attributes(self)
    assert(self.maxlength, 'string field must define `maxlength`')
end
function string._make_native_validators_for_client_to_lua(self, validators)
    if self.minlength and self.minlength > 0 then
        table.insert(validators, 1, Validator.minlength{
            name = self.label, 
            message = self.error_messages.minlength, 
            number = self.minlength})
    end 
    if self.maxlength then
        table.insert(validators, 1, Validator.maxlength{
            name = self.label, 
            message = self.error_messages.maxlength, 
            number = self.maxlength})
    end
    basefield._make_native_validators_for_client_to_lua(self, validators)
end


local integer = setmetatable({type='integer'}, basefield)
integer.__index = integer
integer.__call = __call
function integer._make_native_validators_for_client_to_lua(self, validators)
    if self.min then
        table.insert(validators, 1, Validator.min{
            name = self.label, 
            message = self.error_messages.min, 
            number = self.min})
    end 
    if self.max then
        table.insert(validators, 1, Validator.max{
            name = self.label, 
            message = self.error_messages.max, 
            number = self.max})
    end
    table.insert(validators, 1, Validator.integer)
    basefield._make_native_validators_for_client_to_lua(self, validators)
end


local float = setmetatable({type='float'}, basefield)
float.__index = float
float.__call = __call
function float._make_native_validators_for_client_to_lua(self, validators)
    if self.min then
        table.insert(validators, 1, Validator.min{
            name = self.label, 
            message = self.error_messages.min, 
            number = self.min})
    end 
    if self.max then
        table.insert(validators, 1, Validator.max{
            name = self.label, 
            message = self.error_messages.max, 
            number = self.max})
    end
    table.insert(validators, 1, Validator.number)
    basefield._make_native_validators_for_client_to_lua(self, validators)
end


local json = setmetatable({type='json', db_type="varchar"}, string)
json.__index = json
json.__call = __call
function json.new(cls, attrs)
    if attrs.maxlength == nil then
        attrs.maxlength = 3000
    end
    return string.new(cls, attrs)
end
function json._make_native_validators_for_client_to_lua(self, validators)
    table.insert(validators, 1, Validator.decode)
    string._make_native_validators_for_client_to_lua(self, validators)
end
function json._make_native_validators_for_db_to_lua(self, validators)
    table.insert(validators, 1, Validator.decode)
    string._make_native_validators_for_db_to_lua(self, validators)
end
function json._make_native_validators_for_lua_to_db(self, validators)
    table.insert(validators, Validator.encode)
    string._make_native_validators_for_lua_to_db(self, validators)
end


local array = setmetatable({type='array', db_type="varchar"}, json)
array.__index = array
array.__call = __call
function array._make_native_validators_for_client_to_lua(self, validators)
    if self.required then
        table.insert(validators, 1, Validator.forbid_empty_array{
            name = self.label, 
            message = self.error_messages.required})
    end
    table.insert(validators, 1, Validator.encode_as_array)
    json._make_native_validators_for_client_to_lua(self, validators)
end
function array._make_native_validators_for_db_to_lua(self, validators)
    table.insert(validators, 1, Validator.encode_as_array)
    json._make_native_validators_for_db_to_lua(self, validators)
end
-- function array._make_native_validators_for_lua_to_db(self, validators)
--     -- **暂时不放出此方法, 因为client_to_lua已经保证了空表会被编码为[]
--     -- 除非以后出现单独使用lua_to_db方法的需求
--     table.insert(validators, Validator.encode_as_array)
--     json._make_native_validators_for_lua_to_db(self, validators)
-- end
function array.match_choices(self, choices, value)
    for i, v in ipairs(value) do
        if not choices[v] then
            return false
        end
    end
    return true
end


local function row_make_client_to_lua_validator(field)
    return function (rows, model)
        local err
        for r, row in ipairs(rows) do
            for j, subfield in ipairs(field.subfields) do
                local c = subfield.name
                row[c], err = subfield.client_to_lua(row[c], model)
                if err then
                    return nil, err, r, c
                end
            end
        end
        return rows
    end
end
local function row_make_lua_to_db_validator(field)
    return function (rows, model)
        local err
        for r, row in ipairs(rows) do
            for j, subfield in ipairs(field.subfields) do
                local c = subfield.name
                row[c], err = subfield.lua_to_db(row[c], model)
                if err then
                    return nil, err, r, c
                end
            end
        end
        return rows
    end
end
local function row_make_db_to_lua_validator(field)
    return function (rows, model)
        local err
        for r, row in ipairs(rows) do
            for j, subfield in ipairs(field.subfields) do
                local c = subfield.name
                row[c], err = subfield.db_to_lua(row[c], model)
                if err then
                    return nil, err, r, c
                end
            end
        end
        return rows
    end
end
local VALID_ROW_TYPES = {
    string = true, 
    integer = true, 
    float = true, 
    datetime = true, 
    date = true, 
    time = true, 
    foreignkey = true, 
}
local row = setmetatable({type='row', db_type="varchar"}, array)
row.__index = row
row.__call = __call
function row._check_attributes(self)
    assert(type(self.subfields) == 'table', 'you must define subfields')
    for i, subfield in ipairs(self.subfields) do
        assert(VALID_ROW_TYPES[subfield.type], 'invalid subfield type: '..subfield.type)
    end
    array._check_attributes(self)
end
function row._make_native_validators_for_client_to_lua(self, validators)
    table.insert(validators, 1, row_make_client_to_lua_validator(self))
    array._make_native_validators_for_client_to_lua(self, validators)
end
function row._make_native_validators_for_lua_to_db(self, validators) 
    table.insert(validators, row_make_lua_to_db_validator(self))
    array._make_native_validators_for_lua_to_db(self, validators)
end
function row._make_native_validators_for_db_to_lua(self, validators) 
    table.insert(validators, 1, row_make_db_to_lua_validator(self))
    array._make_native_validators_for_db_to_lua(self, validators)
end

-- default to postgresql
local datetime = setmetatable({type='datetime', db_type='timestamp(0) with time zone'}, basefield)
datetime.__index = datetime
datetime.__call = __call
function datetime.new(cls, attrs)
    if attrs.auto_now_add or attrs.auto_now then
        attrs.default = ngx_localtime
        attrs.required = false
    end
    if attrs.database == 'mysql' then
        attrs.db_type = 'datetime'
    end
    return basefield.new(cls, attrs)
end
function datetime._make_native_validators_for_client_to_lua(self, validators)
    if self.auto_now_add or self.auto_now  then
        -- by design, any client_to_lua validator is unnecessary, so do nothing.
    else
        basefield._make_native_validators_for_client_to_lua(self, validators)
    end
end


local date = setmetatable({type='date'}, basefield)
date.__index = date
date.__call = __call


local time = setmetatable({type='time', db_type='time with time zone'}, basefield)
time.__index = time
time.__call = __call
function time.new(cls, attrs)
    if attrs.database == 'mysql' then
        attrs.db_type = 'time'
    end
    return basefield.new(cls, attrs)
end


local function foreignkey_db_to_lua_validator(fk_model)
    local function __index(t, key)
        -- perform sql only when key is in fields:
        if fk_model.fields_dict[key] then
            local res, err = fk_model:get('id='..t.id)
            if not res then
                return nil
            end
            for k, v in pairs(res) do
                rawset(t, k, v)
            end
            setmetatable(t, fk_model) -- become an instance of fk_model
            return t[key]
        else
            return fk_model[key] -- otherwise try to return attributes of fk_model
        end
    end
    -- local function __newindex(t, key, value)
    --     -- perform sql only when key is in fields:
    --     if fk_model.fields_dict[key] then
    --         local res, err = fk_model:get('id='..t.id)
    --         if not res then
    --             return nil
    --         end
    --         -- update there attributes
    --         for k, v in pairs(res) do
    --             rawset(t, k, v)
    --         end
    --         setmetatable(t, fk_model) -- become an instance of fk_model
    --         t[key] = value
    --     else
    --         rawset(t, key, value)
    --     end
    -- end
    local function validator(v)
        return setmetatable({id = v}, {__index = __index})
    end
    return validator
end
local function foreignkey_lua_to_db_validator(v)
    if type(v) == 'table' then
        v = v.id
    end
    v = tonumber(v)
    if v then
        return v
    else
        return nil, 'foreignkey must be a number or table whose key `id` is a number'
    end
end
local foreignkey = setmetatable({type='foreignkey', db_type='integer'}, basefield)
foreignkey.__index = foreignkey
foreignkey.__call = __call
function foreignkey._check_attributes(self)
    basefield._check_attributes(self)
    assert(type(self.reference)=='table', 'a foreign key must define reference.')
end
function foreignkey._make_native_validators_for_client_to_lua(self, validators)
    table.insert(validators, 1, Validator.integer)
    basefield._make_native_validators_for_client_to_lua(self, validators)
end
function foreignkey._make_native_validators_for_lua_to_db(self, validators)
    table.insert(validators, foreignkey_lua_to_db_validator)
    basefield._make_native_validators_for_lua_to_db(self, validators)
end
function foreignkey._make_native_validators_for_db_to_lua(self, validators)
    table.insert(validators, 1, foreignkey_db_to_lua_validator(self.reference))
    basefield._make_native_validators_for_db_to_lua(self, validators)
end


return {
    string = string, 
    integer = integer, 
    float = float, 
    datetime = datetime, 
    date = date,
    time = time,
    json = json,
    array = array,
    row = row,
    foreignkey = foreignkey,
    VALIDATE_STAGES = VALIDATE_STAGES,
}