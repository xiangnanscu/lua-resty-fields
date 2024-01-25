local clone = require "table.clone"
local isarray = require("table.isarray")
local Validators = require "resty.validator"
local Array = require "resty.array"
local getenv = require("resty.dotenv").getenv
local get_payload = require "resty.alioss".get_payload
local string_format = string.format
local table_concat = table.concat
local table_insert = table.insert
local ipairs = ipairs
local setmetatable = setmetatable
local type = type
local rawset = rawset
local ngx_localtime = ngx.localtime


local function dict(a, b)
  local t = clone(a)
  if b then
    for k, v in pairs(b) do
      t[k] = v
    end
  end
  return t
end

local function list(a, b)
  local t = clone(a)
  if b then
    for _, v in ipairs(b) do
      t[#t + 1] = v
    end
  end
  return t
end

local function map(tbl, func)
  local res = Array()
  for i = 1, #tbl do
    res[i] = func(tbl[i])
  end
  return res
end

---@param s string
---@param sep? string
---@return array
local function split(s, sep)
  local res = {}
  sep = sep or ""
  local i = 1
  local a, b
  while true do
    a, b = s:find(sep, i, true)
    if a then
      local e = s:sub(i, a - 1)
      i = b + 1
      res[#res + 1] = e
    else
      res[#res + 1] = s:sub(i)
      return res
    end
  end
end

local INHERIT_METHODS = {
  new = true,
  __add = true,
  __sub = true,
  __mul = true,
  __div = true,
  __mod = true,
  __pow = true,
  __unm = true,
  __concat = true,
  __len = true,
  __eq = true,
  __lt = true,
  __le = true,
  __index = true,
  __newindex = true,
  __call = true,
  __tostring = true
}
local function class_new(cls, self)
  return setmetatable(self or {}, cls)
end

local function class__call(cls, attrs)
  local self = cls:new()
  self:init(attrs)
  return self
end

local function class__init(self, attrs)

end

---make a class with methods: __index, __call, class, new
---@param cls table
---@param parent? table
---@param copy_parent? boolean
---@return table
local function class(cls, parent, copy_parent)
  if parent then
    if copy_parent then
      for key, value in pairs(parent) do
        if cls[key] == nil then
          cls[key] = value
        end
      end
    end
    setmetatable(cls, parent)
    for method, _ in pairs(INHERIT_METHODS) do
      if cls[method] == nil and parent[method] ~= nil then
        cls[method] = parent[method]
      end
    end
  end
  function cls.class(cls, subcls, copy_parent)
    return class(subcls, cls, copy_parent)
  end

  cls.new = cls.new or class_new
  cls.init = cls.init or class__init
  cls.__call = cls.__call or class__call
  cls.__index = cls
  return cls
end

local function utf8len(s)
  local _, cnt = s:gsub("[^\128-\193]", "")
  return cnt
end

local size_table = {
  k = 1024,
  m = 1024 * 1024,
  g = 1024 * 1024 * 1024,
  kb = 1024,
  mb = 1024 * 1024,
  gb = 1024 * 1024 * 1024
}
local function byte_size_parser(t)
  if type(t) == "string" then
    local unit = t:gsub("^(%d+)([^%d]+)$", "%2"):lower()
    local ts = t:gsub("^(%d+)([^%d]+)$", "%1"):lower()
    local bytes = size_table[unit]
    assert(bytes, "invalid size unit: " .. unit)
    local num = tonumber(ts)
    assert(num, "can't convert `" .. ts .. "` to a number")
    return num * bytes
  elseif type(t) == "number" then
    return t
  else
    error("invalid type:" .. type(t))
  end
end

local basefield
local string
local sfzh
local email
local password
local text
local integer
local float
local datetime
local date
local year_month
local year
local month
local time
local json
local array
local table
local foreignkey
local boolean
local alioss
local alioss_image
local alioss_list
local alioss_image_list

local function get_fields()
  return {
    basefield = basefield,
    string = string,
    sfzh = sfzh,
    email = email,
    password = password,
    text = text,
    integer = integer,
    float = float,
    datetime = datetime,
    date = date,
    year_month = year_month,
    year = year,
    month = month,
    time = time,
    json = json,
    array = array,
    table = table,
    foreignkey = foreignkey,
    boolean = boolean,
    alioss = alioss,
    alioss_image = alioss_image,
    alioss_list = alioss_list,
    alioss_image_list = alioss_image_list,
  }
end

local TABLE_MAX_ROWS = 1
local CHOICES_ERROR_DISPLAY_COUNT = 30
local DEFAULT_ERROR_MESSAGES = { required = "此项必填", choices = "无效选项" }
local DEFAULT_BOOLEAN_CHOICES = { { label = '是', value = true }, { label = '否', value = false } }
local VALID_FOREIGN_KEY_TYPES = {
  foreignkey = tostring,
  string = tostring,
  sfzh = tostring,
  integer = Validators.integer,
  float = tonumber,
  datetime = Validators.datetime,
  date = Validators.date,
  time = Validators.time
}
-- local PRIMITIVES = {
--   string = true,
--   number = true,
--   boolean = true,
--   table = true,
-- }
local NULL = ngx.null

local FK_TYPE_NOT_DEFIEND = {}

local function clean_choice(c)
  local v
  if c.value ~= nil then
    v = c.value
  else
    v = c[1]
  end
  assert(v ~= nil, "you must provide a value for a choice")
  local l
  if c.label ~= nil then
    l = c.label
  elseif c[2] ~= nil then
    l = c[2]
  else
    l = v
  end
  return v, l, (c.hint or c[3])
end
local function string_choices_to_array(s)
  local choices = Array {}
  local spliter = s:find('\n') and '\n' or ','
  for _, line in ipairs(split(s, spliter)) do
    line = assert(Validators.trim(line))
    if line ~= "" then
      choices[#choices + 1] = line
    end
  end
  return choices
end
local function get_choices(raw_choices)
  if type(raw_choices) == 'string' then
    raw_choices = string_choices_to_array(raw_choices)
  end
  if type(raw_choices) ~= 'table' then
    error(string_format("choices type must be table ,not %s", type(raw_choices)))
  end
  local choices = Array {}
  for i, c in ipairs(raw_choices) do
    if type(c) == "string" then
      c = { value = c, label = c }
    elseif type(c) == "number" or type(c) == "boolean" then
      c = { value = c, label = tostring(c) }
    elseif type(c) == "table" then
      local value, label, hint = clean_choice(c)
      c = { value = value, label = label, hint = hint }
    else
      error("invalid choice type:" .. type(c))
    end
    choices[#choices + 1] = c
  end
  return choices
end

local function serialize_choice(choice)
  return tostring(choice.value)
end

local function get_choices_error_message(choices)
  local valid_choices = table_concat(map(choices, serialize_choice), "，")
  return string_format("限下列选项：%s", valid_choices)
end

local function get_choices_validator(choices, message)
  if #choices <= CHOICES_ERROR_DISPLAY_COUNT then
    message = string_format("%s，%s", message, get_choices_error_message(choices))
  end
  local is_choice = {}
  for _, c in ipairs(choices) do
    is_choice[c.value] = true
  end
  local function choices_validator(value)
    if not is_choice[value] then
      return nil, message
    else
      return value
    end
  end

  return choices_validator
end

local shortcuts_names = { 'name', 'label', 'type', 'required' }
local function normalize_field_shortcuts(field)
  field = clone(field)
  for i, prop in ipairs(shortcuts_names) do
    if field[prop] == nil and field[i] ~= nil then
      field[prop] = field[i]
      field[i] = nil
    end
  end
  return field
end

local base_option_names = {
  "primary_key",
  "null",
  "unique",
  "index",
  "db_type",
  "required",
  "disabled",
  "default",
  "label",
  "hint",
  "error_messages",
  "choices",
  "strict",
  "choices_url",
  "choices_url_admin",
  "choices_url_method",
  "autocomplete",
  "max_display_count", -- 前端autocomplete.choices最大展示数
  "max_choices_count", -- 前端autocomplete.choices最大数
  "preload",
  "lazy",
  "tag",
  "group", -- fui联动choices
  "attrs",
}
---@type Field
basefield = class {
  __is_field_class__ = true,
  option_names = {},
  normalize_field_shortcuts = normalize_field_shortcuts,
  __call = function(cls, options)
    return cls:create_field(options)
  end,
  create_field = function(cls, options)
    local self = cls:new {}
    self:init(options)
    self.validators = self:get_validators {}
    return self
  end,
  new = function(cls, self)
    return setmetatable(self or {}, cls)
  end,
  init = function(self, options)
    self.name = assert(options.name, "you must define a name for a field")
    self.type = options.type
    for _, name in ipairs(self:get_option_names()) do
      if options[name] ~= nil then
        self[name] = options[name]
      end
    end
    if options.attrs then
      self.attrs = clone(options.attrs)
    end
    if self.required == nil then
      self.required = false
    end
    if self.db_type == nil then
      self.db_type = self.type
    end
    if self.label == nil then
      self.label = self.name
    end
    if self.null == nil then
      if self.required or self.db_type == 'varchar' or self.db_type == 'text' then
        self.null = false
      else
        self.null = true
      end
    end
    if type(self.choices) == 'table' or type(self.choices) == 'string' then
      self.choices = get_choices(self.choices)
    end
    if self.autocomplete then
      if self.max_choices_count == nil then
        self.max_choices_count = getenv('MAX_CHOICES_COUNT') or 100
      end
      if self.max_display_count == nil then
        self.max_display_count = getenv('MAX_DISPLAY_COUNT') or 50
      end
    end
    return self
  end,
  get_option_names = function(self)
    return list(base_option_names, self.option_names)
  end,
  get_error_message = function(self, key)
    if self.error_messages and self.error_messages[key] then
      return self.error_messages[key]
    end
    return DEFAULT_ERROR_MESSAGES[key]
  end,
  get_validators = function(self, validators)
    if self.required then
      table_insert(validators, 1, Validators.required(self:get_error_message('required')))
    else
      table_insert(validators, 1, Validators.not_required)
    end
    -- if type(self.choices_url) == 'string' and self.strict then
    --   local function dynamic_choices_validator(val)
    --     local message = self:get_error_message('choices')
    --     local choices = get_choices(http[self.choices_url_method or 'get'](self.choices_url).body)
    --     for _, c in ipairs(choices) do
    --       if val == c.value then
    --         return val
    --       end
    --     end
    --     if #choices <= CHOICES_ERROR_DISPLAY_COUNT then
    --       message = string_format("%s，%s", message, get_choices_error_message(choices))
    --     end
    --     return nil, message
    --   end
    --   table_insert(validators, dynamic_choices_validator)
    -- end
    if type(self.choices) == 'table' and self.choices[1] and (self.strict == nil or self.strict) then
      self.static_choice_validator = get_choices_validator(self.choices, self:get_error_message('choices'))
      table_insert(validators, self.static_choice_validator)
    end
    return validators
  end,
  get_options = function(self)
    local ret = {
      name = self.name,
      type = self.type,
    }
    for _, name in ipairs(self:get_option_names()) do
      if self[name] ~= nil then
        ret[name] = self[name]
      end
    end
    if ret.attrs then
      ret.attrs = clone(ret.attrs)
    end
    return ret
  end,
  json = function(self)
    local res = self:get_options()
    if type(res.default) == 'function' then
      res.default = nil
    end
    if type(res.choices) == 'function' then
      res.choices = nil
    end
    if not res.tag then
      if type(res.choices) == 'table' and #res.choices > 0 and not res.autocomplete then
        res.tag = "select"
      else
        res.tag = "input"
      end
    end
    if res.tag == "input" and res.lazy == nil then
      res.lazy = true
    end
    if res.preload == nil and (res.choices_url or res.choices_url_admin) then
      res.preload = false
    end
    return res
  end,
  widget_attrs = function(self, extra_attrs)
    return dict({ required = self.required, readonly = self.disabled }, extra_attrs)
  end,
  validate = function(self, value, ctx)
    if type(value) == 'function' then
      return value
    end
    local err, index
    for _, validator in ipairs(self.validators) do
      value, err, index = validator(value, ctx)
      if value ~= nil then
        if err == nil then
        elseif value == err then
          -- 代表保持原值,跳过此阶段的所有验证
          return value
        else
          return nil, err, index
        end
      elseif err ~= nil then
        return nil, err, index
      else
        -- not-required validator, skip the rest validations
        return nil
      end
    end
    return value
  end,
  get_default = function(self, ctx)
    if type(self.default) ~= "function" then
      return self.default
    else
      return self.default(ctx)
    end
  end,
  make_error = function(self, message, index)
    return {
      type = 'field_error',
      message = message,
      index = index,
      name = self.name,
      label = self.label,
    }
  end,
  to_form_value = function(self, value)
    return value
  end,
  to_post_value = function(self, value)
    return value
  end
}

local function get_max_choice_length(choices)
  local n = 0
  for _, c in ipairs(choices) do
    local value = c.value
    local n1 = utf8len(value)
    if n1 > n then
      n = n1
    end
  end
  return n
end

string = basefield:class {
  option_names = {
    "compact",
    "trim",
    "pattern",
    "length",
    "minlength",
    "maxlength",
    "input_type",
  },
  init = function(self, options)
    if not options.choices and not options.length and not options.maxlength then
      error(string_format("field '%s' must define maxlength or choices or length", options.name))
    end
    basefield.init(self, dict({
      type = "string",
      db_type = "varchar",
      compact = true,
      trim = true,
    }, options))
    --TODO:考虑default为函数时,数据库层面应该为空字符串.从migrate.lua的serialize_defaut特定可以考虑default函数传入nil时认定为migrate的情形, 自行返回空字符串
    if self.default == nil and not self.primary_key and not self.unique then
      self.default = ""
    end
    if self.choices and #self.choices > 0 then
      local n = get_max_choice_length(self.choices)
      assert(n > 0, "invalid string choices(empty choices or zero length value):" .. self.name)
      local m = self.length or self.maxlength
      if not m or n > m then
        self.maxlength = n
      end
    end
  end,
  get_validators = function(self, validators)
    for _, e in ipairs { "pattern", "length", "minlength", "maxlength" } do
      if self[e] then
        table_insert(validators, 1, Validators[e](self[e], self:get_error_message(e)))
      end
    end
    if self.compact then
      table_insert(validators, 1, Validators.delete_spaces)
    elseif self.trim then
      table_insert(validators, 1, Validators.trim)
    end
    table_insert(validators, 1, Validators.string)
    return basefield.get_validators(self, validators)
  end,
  widget_attrs = function(self, extra_attrs)
    local attrs = {
      -- maxlength = self.maxlength,
      minlength = self.minlength
      -- pattern = self.pattern,
    }
    return dict(basefield.widget_attrs(self), dict(attrs, extra_attrs))
  end,
  to_form_value = function(self, value)
    if not value then
      return ""
    elseif type(value) == 'string' then
      return value
    else
      return tostring(value)
    end
  end,
  to_post_value = function(self, value)
    if self.compact then
      if not value then
        return ""
      else
        return value:gsub('%s', '')
      end
    else
      return value or ""
    end
  end
}

text = basefield:class {
  option_names = { "trim", "pattern" },
  init = function(self, options)
    basefield.init(self, dict({
      type = "text",
      db_type = "text",
    }, options))
    if self.default == nil then
      self.default = ""
    end
    if self.attrs and self.attrs.auto_size == nil then
      self.attrs.auto_size = false
    end
  end,
}

sfzh = string:class {
  option_names = { unpack(string.option_names) },
  init = function(self, options)
    string.init(self, dict({
      type = "sfzh",
      db_type = "varchar",
      length = 18
    }, options))
  end,
  get_validators = function(self, validators)
    table_insert(validators, 1, Validators.sfzh)
    return string.get_validators(self, validators)
  end,
}

email = string:class {
  option_names = { unpack(string.option_names) },
  init = function(self, options)
    string.init(self, dict({
      type = "email",
      db_type = "varchar",
      maxlength = 255
    }, options))
  end,
  get_validators = function(self, validators)
    table_insert(validators, 1, Validators.email)
    return string.get_validators(self, validators)
  end,
}

password = string:class {
  option_names = { unpack(string.option_names) },
  init = function(self, options)
    string.init(self, dict({
      type = "password",
      db_type = "varchar",
      maxlength = 255
    }, options))
  end
}

year_month = string:class {
  option_names = { unpack(string.option_names) },
  init = function(self, options)
    string.init(self, dict({
      type = "year_month",
      db_type = "varchar",
      maxlength = 7
    }, options))
  end,
  get_validators = function(self, validators)
    table_insert(validators, 1, Validators.year_month)
    return basefield.get_validators(self, validators)
  end,
}

local function add_min_or_max_validators(self, validators)
  for _, name in ipairs({ "min", "max" }) do
    if self[name] then
      table_insert(validators, 1, Validators[name](self[name], self:get_error_message(name)))
    end
  end
end

integer = basefield:class {
  option_names = { "min", "max", "step", "serial" },
  init = function(self, options)
    basefield.init(self, dict({
      type = "integer",
      db_type = "integer",
    }, options))
  end,
  get_validators = function(self, validators)
    add_min_or_max_validators(self, validators)
    table_insert(validators, 1, Validators.integer)
    return basefield.get_validators(self, validators)
  end,
  json = function(self)
    local json = basefield.json(self)
    if json.primary_key and json.disabled == nil then
      json.disabled = true
    end
    return json
  end,
  prepare_for_db = function(self, value)
    if value == "" or value == nil then
      return NULL
    else
      return value
    end
  end
}

year = integer:class {
  option_names = { unpack(integer.option_names) },
  init = function(self, options)
    integer.init(self, dict({
      type = "year",
      db_type = "integer",
      min = 1000,
      max = 9999
    }, options))
  end,
}

month = integer:class {
  option_names = { unpack(integer.option_names) },
  init = function(self, options)
    integer.init(self, dict({
      type = "month",
      db_type = "integer",
      min = 1,
      max = 12
    }, options))
  end,
}

float = basefield:class {
  option_names = { "min", "max", "step", "precision" },
  init = function(self, options)
    basefield.init(self, dict({
      type = "float",
      db_type = "float",
    }, options))
  end,
  get_validators = function(self, validators)
    add_min_or_max_validators(self, validators)
    table_insert(validators, 1, Validators.number)
    return basefield.get_validators(self, validators)
  end,
  prepare_for_db = function(self, value)
    if value == "" or value == nil then
      return NULL
    else
      return value
    end
  end,
}

boolean = basefield:class {
  option_names = { 'cn' },
  init = function(self, options)
    basefield.init(self, dict({
      type = "boolean",
      db_type = "boolean",
    }, options))
    if self.choices == nil then
      self.choices = clone(DEFAULT_BOOLEAN_CHOICES)
    end
  end,
  get_validators = function(self, validators)
    if self.cn then
      table_insert(validators, 1, Validators.boolean_cn)
    else
      table_insert(validators, 1, Validators.boolean)
    end
    return basefield.get_validators(self, validators)
  end,
  prepare_for_db = function(self, value)
    if value == "" or value == nil then
      return NULL
    else
      return value
    end
  end,
}

datetime = basefield:class {
  option_names = {
    'auto_now_add',
    'auto_now',
    'precision',
    'timezone',
  },
  init = function(self, options)
    basefield.init(self, dict({
      type = "datetime",
      db_type = "timestamp",
      precision = 0,
      timezone = true,
    }, options))
    if self.auto_now_add then
      self.default = ngx_localtime
    end
  end,
  get_validators = function(self, validators)
    table_insert(validators, 1, Validators.datetime)
    return basefield.get_validators(self, validators)
  end,
  json = function(self)
    local ret = basefield.json(self)
    if ret.disabled == nil and (ret.auto_now or ret.auto_now_add) then
      ret.disabled = true
    end
    return ret
  end,
  prepare_for_db = function(self, value)
    if self.auto_now then
      return ngx_localtime()
    elseif value == "" or value == nil then
      return NULL
    else
      return value
    end
  end,
}

date = basefield:class {
  option_names = {},
  init = function(self, options)
    basefield.init(self, dict({
      type = "date",
      db_type = "date",
    }, options))
  end,
  get_validators = function(self, validators)
    table_insert(validators, 1, Validators.date)
    return basefield.get_validators(self, validators)
  end,
  prepare_for_db = function(self, value)
    if value == "" or value == nil then
      return NULL
    else
      return value
    end
  end,
}

time = basefield:class {
  option_names = { 'precision', 'timezone' },
  init = function(self, options)
    basefield.init(self, dict({
      type = "time",
      db_type = "time",
      precision = 0,
      timezone = true,
    }, options))
  end,
  get_validators = function(self, validators)
    table_insert(validators, 1, Validators.time)
    return basefield.get_validators(self, validators)
  end,
  prepare_for_db = function(self, value)
    if value == "" or value == nil then
      return NULL
    else
      return value
    end
  end,
}

foreignkey = basefield:class {
  option_names = {
    "json_non_fk",
    "reference",
    "reference_column",
    "reference_label_column",
    "reference_url",
    "reference_url_admin",
    "on_delete",
    "on_update",
    "table_name",
    "admin_url_name",
    "models_url_name",
    "keyword_query_name",
    "limit_query_name",
  },
  init = function(self, options)
    basefield.init(self, dict({
      type = "foreignkey",
      db_type = FK_TYPE_NOT_DEFIEND,
      FK_TYPE_NOT_DEFIEND = FK_TYPE_NOT_DEFIEND,
      on_delete = 'CASCADE',
      on_update = 'CASCADE',
      admin_url_name = 'admin',
      models_url_name = 'model',
      keyword_query_name = 'keyword',
      limit_query_name = 'limit',
      convert = tostring,
    }, options))
    local fk_model = self.reference
    if fk_model == "self" then
      -- used with Xodel._make_model_class
      return self
    end
    self:setup_with_fk_model(fk_model)
  end,
  setup_with_fk_model = function(self, fk_model)
    --setup: reference_column, reference_label_column, db_type
    assert(type(fk_model) == "table" and fk_model.__is_model_class__,
      string_format("a foreignkey must define a reference model. not %s(type: %s)", fk_model, type(fk_model)))
    local rc = self.reference_column or fk_model.primary_key or fk_model.DEFAULT_PRIMARY_KEY or "id"
    local fk = fk_model.fields[rc]
    assert(fk, string_format("invalid foreignkey name %s for foreign model %s",
      rc,
      fk_model.table_name or "[TABLE NAME NOT DEFINED YET]"))
    self.reference_column = rc
    local rlc = self.reference_label_column or fk_model.referenced_label_column or rc
    local _fk, _fk_of_fk = rlc:match("(%w+)__(%w+)")
    local check_key = _fk or rlc
    assert(fk_model.fields[check_key], string_format("invalid foreignkey label name %s for foreign model %s",
      check_key,
      fk_model.table_name or "[TABLE NAME NOT DEFINED YET]"))
    self.reference_label_column = rlc
    self.convert = assert(VALID_FOREIGN_KEY_TYPES[fk.type],
      string_format("invalid foreignkey (name:%s, type:%s)", fk.name, fk.type))
    assert(fk.primary_key or fk.unique, "foreignkey must be a primary key or unique key")
    if self.db_type == FK_TYPE_NOT_DEFIEND then
      self.db_type = fk.db_type or fk.type
    end
  end,
  get_validators = function(self, validators)
    local fk_name = self.reference_column
    local function foreignkey_validator(v)
      local err
      if type(v) == "table" then
        v = v[fk_name]
      end
      v, err = self.convert(v)
      if err then
        local label_type = self.reference.fields[self.reference_label_column].type
        local value_type = self.reference.fields[self.reference_column].type
        if label_type ~= value_type then
          return nil, "输入错误" --前端autocomplete可能传来label值
        end
        return nil, tostring(err)
      end
      return v
    end

    table_insert(validators, 1, foreignkey_validator)
    return basefield.get_validators(self, validators)
  end,
  load = function(self, value)
    local fk_name = self.reference_column
    local fk_model = self.reference
    local function __index(t, key)
      if fk_model[key] then
        -- perform sql only when key is in fields:
        return fk_model[key]
      elseif fk_model.fields[key] then
        local pk = rawget(t, fk_name)
        if not pk then
          return nil
        end
        local res = fk_model:get { [fk_name] = pk }
        if not res then
          return nil
        end
        for k, v in pairs(res) do
          rawset(t, k, v)
        end
        -- become an instance of fk_model
        fk_model:create_record(t)
        return t[key]
      else
        return nil
      end
    end

    return setmetatable({ [fk_name] = value }, { __index = __index })
  end,
  json = function(self)
    if self.json_non_fk then
      local ret = {
        name = self.name,
        label = self.label,
      }
      ret.type = self.reference.fields[self.reference_column].type
      if ret.choices_url == nil then
        ret.choices_url = string_format([[/%s/choices?value=%s&label=%s]],
          self.reference.table_name,
          self.reference_column,
          self.reference_label_column)
      end
      return ret
    end
    local ret = basefield.json(self)
    ret.reference = self.reference.table_name
    if self.autocomplete == nil then
      ret.autocomplete = true
    end
    ret.choices_url_admin = string_format([[/%s/%s/%s/fk/%s/%s]],
      ret.admin_url_name,
      ret.models_url_name,
      ret.table_name,
      ret.name,
      ret.reference_label_column)
    ret.reference_url_admin = string_format([[/%s/%s/%s]],
      ret.admin_url_name,
      ret.models_url_name,
      ret.reference)
    if ret.choices_url == nil then
      ret.choices_url = string_format([[/%s/choices?value=%s&label=%s]],
        ret.reference,
        ret.reference_column,
        ret.reference_label_column)
    end
    if ret.reference_url == nil then
      ret.reference_url = string_format([[/%s/json]], ret.reference)
    end
    return ret
  end,
  prepare_for_db = function(self, value)
    if value == "" or value == nil then
      return NULL
    else
      return value
    end
  end,
  to_form_value = function(self, value)
    if type(value) == "table" then
      return value[self.reference_column]
    else
      return value
    end
  end
}

json = basefield:class {
  option_names = {},
  init = function(self, options)
    basefield.init(self, dict({
      type = "json",
      db_type = "jsonb",
    }, options))
  end,
  json = function(self)
    local json = basefield.json(self)
    json.tag = "textarea"
    return json
  end,
  prepare_for_db = function(self, value)
    if value == "" or value == nil then
      return NULL
    else
      return Validators.encode(value)
    end
  end,
}

local function skip_validate_when_string(v)
  if type(v) == "string" then
    return v, v
  else
    return v
  end
end

local function check_array_type(v)
  if type(v) ~= "table" then
    return nil, "value of array field must be a array"
  else
    return v
  end
end

local function non_empty_array_required(message)
  message = message or "此项必填"
  local function array_required_validator(v)
    if #v == 0 then
      return nil, message
    else
      return v
    end
  end

  return array_required_validator
end


local basearray = json:class {
  init = function(self, options)
    json.init(self, options)
    if type(self.default) == 'string' then
      self.default = string_choices_to_array(self.default)
    end
  end,
  get_validators = function(self, validators)
    if self.required then
      table_insert(validators, 1, non_empty_array_required(self:get_error_message('required')))
    end
    table_insert(validators, 1, check_array_type)
    table_insert(validators, 1, skip_validate_when_string)
    table_insert(validators, Validators.encode_as_array)
    return json.get_validators(self, validators)
  end,
  get_empty_value_to_update = function()
    return Array()
  end,
  to_form_value = function(value)
    if isarray(value) then
      return clone(value)
    else
      return {}
    end
  end
}

array = basearray:class {
  option_names = { 'field', 'min' },
  init = function(self, options)
    basearray.init(self, dict({
      type = "array",
      min = 1,
    }, options))
    assert(type(self.field) == 'table', string_format('array field "%s" must define field', self.name))
    self.field = normalize_field_shortcuts(self.field)
    if not self.field.name then
      self.field.name = self.name
    end
    local fields = get_fields()
    local array_field_cls = fields[self.field.type or 'string']
    if not array_field_cls then
      error("invalid array field type: " .. self.field.type)
    end
    self.field = array_field_cls:create_field(self.field)
  end,
  get_options = function(self)
    local options = basefield.get_options(self)
    local array_field_options = self.field:get_options()
    options.field = array_field_options
    return options
  end,
  get_validators = function(self, validators)
    local function array_validator(value)
      local res = {}
      local field = self.field
      for i, e in ipairs(value) do
        local val, err = field:validate(e)
        if err ~= nil then
          return nil, err, i
        end
        if field.default and (val == nil or val == "") then
          if type(field.default) ~= "function" then
            val = field.default
          else
            val, err = field.default()
            if val == nil then
              return nil, err, i
            end
          end
        end
        res[i] = val
      end
      return res
    end
    table_insert(validators, 1, array_validator)
    return basearray.get_validators(self, validators)
  end,
}

local function make_empty_array()
  return Array()
end

table = basearray:class {
  option_names = { 'model', 'max_rows', 'uploadable', 'columns' },
  init = function(self, options)
    basearray.init(self, dict({
      type = "table",
      max_rows = TABLE_MAX_ROWS,
    }, options))
    if type(self.model) ~= 'table' then
      error("please define model for a table field: " .. self.name)
    end
    if not self.model.__is_model_class__ then
      self.model = require("xodel.model"):create_model {
        extends = self.model.extends,
        mixins = self.model.mixins,
        abstract = self.model.abstract,
        admin = self.model.admin,
        table_name = self.model.table_name,
        label = self.model.label,
        fields = self.model.fields,
        field_names = self.model.field_names,
        auto_primary_key = self.model.auto_primary_key,
        primary_key = self.model.primary_key,
        unique_together = self.model.unique_together
      }
    end
    if not self.default or self.default == "" then
      self.default = make_empty_array
    end
    if not self.model.table_name then
      self.model:materialize_with_table_name { table_name = self.name, label = self.label }
    end
  end,
  get_validators = function(self, validators)
    local function validate_by_each_field(rows)
      local err
      for i, row in ipairs(rows) do
        assert(type(row) == "table", "elements of table field must be table")
        row, err = self.model:validate_create(row)
        if row == nil then
          return nil, err, i
        end
        rows[i] = row
      end
      return rows
    end

    table_insert(validators, 1, validate_by_each_field)
    return basearray.get_validators(self, validators)
  end,
  json = function(self)
    local ret = basearray.json(self)
    local model = {
      field_names = Array {},
      fields = {},
      table_name = self.model.table_name,
      label = self.model.label
    }
    for _, name in ipairs(self.model.field_names) do
      local field = self.model.fields[name]
      model.field_names:push(name)
      model.fields[name] = field:json()
    end
    ret.model = model
    return ret
  end,
  load = function(self, rows)
    if type(rows) ~= 'table' then
      error('value of table field must be table, not ' .. type(rows))
    end
    for i = 1, #rows do
      rows[i] = self.model:load(rows[i])
    end
    return Array(rows)
  end,
}

local ALIOSS_BUCKET = getenv("ALIOSS_BUCKET") or ""
local ALIOSS_REGION = getenv("ALIOSS_REGION") or ""
local ALIOSS_SIZE = getenv("ALIOSS_SIZE") or "1M"
local ALIOSS_LIFETIME = tonumber(getenv("ALIOSS_LIFETIME") or 30);
alioss = string:class {
  option_names = {
    "size",
    "size_arg",
    "policy",
    "payload",
    "lifetime",
    "key_secret",
    "key_id",
    "times",
    "width",
    "hash",
    "image",
    "prefix",
    "upload_url",
    "payload_url",
    "input_type",
    "limit",
    "media_type",
    unpack(string.option_names)
  },
  init = function(self, options)
    string.init(self, dict({
      type = "alioss",
      db_type = "varchar",
      maxlength = 255
    }, options))
    self:setup(options)
  end,
  setup = function(self, options)
    local size = options.size or ALIOSS_SIZE
    self.key_secret = options.key_secret
    self.key_id = options.key_id
    self.size_arg = size
    self.size = byte_size_parser(size)
    self.lifetime = options.lifetime or ALIOSS_LIFETIME
    self.upload_url = string_format("//%s.%s.aliyuncs.com/",
      options.bucket or ALIOSS_BUCKET,
      options.region or ALIOSS_REGION)
  end,
  get_options = function(self)
    local ret = string.get_options(self)
    ret.size = ret.size_arg
    ret.size_arg = nil
    return ret
  end,
  get_payload = function(self, options)
    return get_payload(dict(self, options))
  end,
  get_validators = function(self, validators)
    table_insert(validators, 1, Validators.url)
    return string.get_validators(self, validators)
  end,
  json = function(self)
    local ret = string.json(self)
    if ret.input_type == nil then
      ret.input_type = "file"
    end
    ret.key_secret = nil
    ret.key_id = nil
    return ret
  end,
  load = function(self, value)
    if value and value:sub(1, 1) == "/" then
      local scheme = getenv('VITE_HTTPS') == 'on' and 'https' or 'http'
      return scheme .. ':' .. value
    else
      return value
    end
  end
}

alioss_image = alioss:class {
  init = function(self, options)
    alioss.init(self, dict({
      type = "alioss_image",
      db_type = "varchar",
      media_type = 'image',
      image = true,
    }, options))
  end,
}

alioss_list = basearray:class {
  option_names = { unpack(alioss.option_names) },
  init = function(self, options)
    basearray.init(self, dict({
      type = "alioss_list",
      db_type = 'jsonb',
    }, options))
    alioss.setup(self, options)
  end,
  get_payload = alioss.get_payload,
  get_options = alioss.get_options,
  json = function(self)
    return dict(alioss.json(self), basearray.json(self))
  end
}

alioss_image_list = alioss_list:class {
  init = function(self, options)
    alioss_list.init(self, dict({
      type = "alioss_image_list",
      -- media_type = 'image',
      -- image = true,
    }, options))
  end,
  -- json = function(self)
  --   local ret = alioss_list.json(self)
  --   ret.type = 'alioss_image_list'
  --   return ret
  -- end,
}

return get_fields()
