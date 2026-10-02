idf_component_register(SRCS "main.cpp" "inputs.cpp" "lights.cpp" "configuration.cpp" "management.cpp" "power.cpp" "vendor/protocol.cpp" "ble/ble.cpp" "ble/bonds.cpp"
    INCLUDE_DIRS "."
    REQUIRES esp_tinyusb json esp_app_format esp_hw_support esp_timer freertos esp_driver_gpio esp_driver_rmt esp_adc driver nvs_flash bt)
