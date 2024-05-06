# The instructions for this image were put together with heavy influence from the Jupyter Docker stack and Pangeo base images. 
# Containerfile for base of all CISL Cloud images
FROM ubuntu:22.04

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Setup environment to match variables set by repo2docker as much as possible
# The name of the conda environment into which the requested packages are installed
ENV CONDA_ENV=cisl-cloud-base \
    # Tell apt-get to not block installs by asking for interactive human input
    DEBIAN_FRONTEND=noninteractive \
    # Set username, uid and gid (same as uid) of non-root user the container will be run as
    NB_USER=jovyan \
    NB_UID=1000 \
    NB_GID=1000 \
    # Use /bin/bash as shell, not the default /bin/sh (arrow keys, etc don't work then)
    SHELL=/bin/bash \
    # Setup locale to be UTF-8, avoiding gnarly hard to debug encoding errors
    LANG=C.UTF-8  \
    LC_ALL=C.UTF-8 \
    # Install conda in the same place repo2docker does
    CONDA_DIR=/srv/conda \
    # Set a directory for the default conda envs to allow for nc_conda_kernels env filtering
    CONDA_USR_DIR=/srv/base-conda 

# All env vars that reference other env vars need to be in their own ENV block
# Path to the python environment where the jupyter notebook packages are installed
ENV NB_PYTHON_PREFIX=${CONDA_USR_DIR}/envs/${CONDA_ENV} \
    # Home directory of our non-root user
    HOME=/home/${NB_USER}

# Add both our notebook env as well as default conda installation to $PATH
# Thus, when we start a `python` process (for kernels, or notebooks, etc),
# it loads the python in the notebook conda environment, as that comes
# first here.
ENV PATH=${CONDA_DIR}/bin:${NB_PYTHON_PREFIX}/bin:${PATH}

# Ask dask to read config from ${CONDA_DIR}/etc rather than
# the default of /etc, since the non-root jovyan user can write
# to ${CONDA_DIR}/etc but not to /etc
ENV DASK_ROOT_CONFIG=${CONDA_USR_DIR}/etc

# Copy in a file that contains all apt packages to install in the image
COPY packages/apt.txt apt.txt

# Install apt packages
RUN echo "Installing Apt-get packages..." \
    && apt-get update --fix-missing > /dev/null \
    && apt-get install -y apt-utils wget zip tzdata > /dev/null \
    && xargs -a apt.txt apt-get install -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
    
###
# Copy a script that we will use to correct permissions after running certain commands
###
COPY scripts/fix-permissions /usr/local/bin/fix-permissions

# Change permissions on the script so it can be run
RUN chmod a+rx /usr/local/bin/fix-permissions

# Create NB_USER with name jovyan user with UID=1000 and in the 'users' group
# and make sure these dirs are writable by the `users` group.
RUN echo "Creating ${NB_USER} user..." \
    # Create a group for the user to be part of, with gid same as uid
    && groupadd --gid ${NB_UID} ${NB_USER}  \
    # Create non-root user, with given gid, uid and create $HOME
    && useradd --create-home --gid ${NB_UID} --no-log-init --uid ${NB_UID} ${NB_USER} \
    # Make sure that /srv is owned by non-root user, so we can install things there
    && chown -R ${NB_USER}:${NB_USER} /srv

# Create the directories where conda environments are going to be installed
RUN mkdir -p "${CONDA_DIR}" && \
    mkdir -p "${CONDA_USR_DIR}" && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "${CONDA_USR_DIR}" && \
    fix-permissions "/home/${NB_USER}"

# Add TZ configuration - https://github.com/PrefectHQ/prefect/issues/3061
ENV TZ UTC
# ========================

# Install latest mambaforge in ${CONDA_DIR}
RUN echo "Installing Mambaforge..." \
    && URL="https://github.com/conda-forge/miniforge/releases/latest/download/Mambaforge-Linux-x86_64.sh" \
    && wget --quiet ${URL} -O installer.sh \
    && /bin/bash installer.sh -u -b -p ${CONDA_DIR} \
    && rm installer.sh \
    && mamba install conda-lock jupyterhub==4.0.1 notebook conda-forge::nb_conda_kernels -y \
    && mamba clean -afy \
    # After installing the packages, we cleanup some unnecessary files
    # to try reduce image size - see https://jcristharif.com/conda-docker-tips.html
    # Although we explicitly do *not* delete .pyc files, as that seems to slow down startup
    # quite a bit unfortunately - see https://github.com/2i2c-org/infrastructure/issues/2047
    && find ${CONDA_DIR} -follow -type f -name '*.a' -delete \
    # Fix permissions
    && fix-permissions "${CONDA_DIR}" \
    && fix-permissions "${CONDA_USR_DIR}" \
    && fix-permissions "/home/${NB_USER}"

# Change to /tmp to work out
WORKDIR /tmp

# Copy pip and conda packages in to tmp
COPY packages/requirements.txt packages/cisl-cloud-base.yml /tmp/

# Install pip packages
RUN ${CONDA_DIR}/bin/pip install --no-cache -r requirements.txt

# Copy the condarc file over to define conda congiruation
COPY --chown="${NB_UID}:${NB_GID}" configs/.condarc "${CONDA_DIR}/.condarc"

# Create the conda envs with mamba to increase installation speed
RUN mamba env create --name ${CONDA_ENV} -f cisl-cloud-base.yml \
    && mamba clean -afy \
    # Fix permissions
    && fix-permissions "${CONDA_DIR}" \
    && fix-permissions "${CONDA_USR_DIR}" \
    && fix-permissions "/home/${NB_USER}"

# Run conda activate each time a bash shell starts, so users don't have to manually type conda activate
# Note this is only read by shell, but not by the jupyter notebook - that relies
# on us starting the correct `python` process, which we do by adding the notebook conda environment's
# bin to PATH earlier ($NB_PYTHON_PREFIX/bin)
RUN echo ". ${CONDA_DIR}/etc/profile.d/conda.sh ; conda activate ${CONDA_ENV}" > /etc/profile.d/init_conda.sh

# Copy the jupyter configuration
COPY configs/jupyter_server_config.py /etc/jupyter/jupyter_server_config.py
# Used to allow user deletions of folders and contents
RUN sed -i 's/c.FileContentsManager.delete_to_trash = False/c.FileContentsManager.always_delete_dir = True/g' /etc/jupyter/jupyter_server_config.py

# Copy default bashrc
COPY configs/.bashrc /etc/bash.bashrc

# Make the conda environments we install read only and executable for the user
# They can run the environments but will get permission denied when trying to make changes
# New environments are installed to /home/jovyan/.jupyter with write permissions for the users
RUN chmod 755 /srv/base-conda/cisl-cloud-base/* && \
    chown root:root /srv/*   

# Cleanup files that were already installed
RUN rm -rf /tmp/cisl-cloud-base.yml && \
    rm -rf /tmp/requirements.txt

# Set the default user to jovyan and make home /hom/jovyan
USER ${NB_USER}
WORKDIR ${HOME}

# Copy over the start script with the correct permissions assigned
COPY --chmod=755 /scripts/start /srv/start

# Expose the port Jupyter runs on
EXPOSE 8888

# The Entrypoint is the /srv/start script
ENTRYPOINT ["/srv/start"]
