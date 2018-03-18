# lua-resty-field
Clean the value via a field object you defined.

# Requirements
[lua-resty-validator](https://github.com/openresty/lua-resty-validator)

# Synopsis
```
local Sql = require"resty.sql.postgresql"

local Profile = {
    table_name = 'profile',
    fields = {
        {name='id'},
        {name='sex'},
    },
}

local foreign_key = {name='p', reference=Profile}
local User = {
    table_name = 'user',
    fields = {
        {name='id'},
        foreign_key,
        {name='name'},
    },
    foreign_keys = {
        p = foreign_key,
    },
}

local sql = Sql:class{model=User}

-- now use sql in your controllers
local s1, err = sql:new{}:where{p__sex='male',name__startswith='k'}:statement()
if err then
    return err
end

local s2, err = sql:new{}:update{name='kate'}:where{id=1}:statement()
if err then
    return err
end


```
